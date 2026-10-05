import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  appendDailyEntry,
  clashCandidate,
  renameClashCandidate,
  retireNoteId,
  usedNoteIds,
  readNoteLog,
  appendNoteLog,
  createNewNoteFile,
  duplicateNoteFile,
  newNoteId,
  parseGeneratedFilename,
  randomNoteId,
  firstLineTitle,
  getDailyFilename,
  parseTitleFromContentOrFilename,
  renameNoteFromTitleIfNeeded,
} from "../src/lib/notes";
import {
  getPinnedPaths,
  movePin,
  reconcilePins,
  removePin,
  togglePin,
} from "../src/lib/pins";
import {
  appendTaskToDaily,
  formatTaskLine,
  listTasks,
  setTaskDone,
} from "../src/lib/tasks";

type Case = [string, () => Promise<void>];

function freshDir(): string {
  return mkdtempSync(path.join(tmpdir(), "notes-test-"));
}

type NameCase = {
  name: string;
  parsed: { stamp: string; id: string | null; slug: string } | null;
  title: string;
  clash: string;
  renameClash: string;
};
const nameCases: NameCase[] = JSON.parse(
  readFileSync(path.join(__dirname, "../test/note-names.json"), "utf8"),
);

const cases: Case[] = [
  [
    "generated names parse as the Swift side parses them (shared fixture)",
    async () => {
      for (const c of nameCases) {
        assert.equal(
          clashCandidate(c.name, 2, () => "zzzz"),
          c.clash,
          c.name,
        );
        assert.equal(renameClashCandidate(c.name, 2), c.renameClash, c.name);
        assert.deepEqual(
          parseGeneratedFilename(c.name) ?? null,
          c.parsed,
          c.name,
        );
      }
    },
  ],
  [
    "an empty note is titled from the slug, never the date, time or id",
    async () => {
      for (const c of nameCases) {
        assert.equal(
          parseTitleFromContentOrFilename(`/n/${c.name}`, "# \n"),
          c.title,
          c.name,
        );
      }
      const title = parseTitleFromContentOrFilename(
        "/n/2026-10-05 1200 ab12 - untitled.md",
        "",
      );
      assert.equal(title, "Untitled");
    },
  ],
  [
    "ids are four base36 characters, drawn again on a clash",
    async () => {
      assert.match(randomNoteId(), /^[0-9a-z]{4}$/);
      const draws = ["ab12", "ab12", "cd34"];
      assert.equal(
        newNoteId(new Set(["ab12"]), () => draws.shift()!),
        "cd34",
      );
    },
  ],
  [
    "a new note gets an id unique in its folder; a rename keeps it",
    async () => {
      const dir = freshDir();
      const first = await createNewNoteFile(dir, "First", "body");
      const second = await createNewNoteFile(dir, "First", "body");
      const a = parseGeneratedFilename(path.basename(first));
      const b = parseGeneratedFilename(path.basename(second));
      assert.ok(a?.id && b?.id && a.id !== b.id, `${first} ${second}`);
      const renamed = await renameNoteFromTitleIfNeeded(first, "Better title");
      const after = parseGeneratedFilename(path.basename(renamed));
      assert.deepEqual(after, {
        stamp: a!.stamp,
        id: a!.id,
        slug: "better-title",
      });
      assert.equal(
        await renameNoteFromTitleIfNeeded(renamed, "Better Title"),
        renamed,
      );
    },
  ],
  [
    "a name from before ids gets one on rename; daily notes stay",
    async () => {
      const dir = freshDir();
      const legacy = path.join(dir, "2026-10-05 1200 - old.md");
      writeFileSync(legacy, "# New\n");
      const renamed = parseGeneratedFilename(
        path.basename(await renameNoteFromTitleIfNeeded(legacy, "New")),
      );
      assert.equal(renamed?.stamp, "2026-10-05 1200");
      assert.match(renamed?.id ?? "", /^[0-9a-z]{4}$/);
      assert.equal(renamed?.slug, "new");
      const daily = path.join(dir, "2026-10-05.md");
      writeFileSync(daily, "# x\n");
      assert.equal(await renameNoteFromTitleIfNeeded(daily, "Other"), daily);
    },
  ],
  [
    "a duplicate gets an id of its own",
    async () => {
      const dir = freshDir();
      const note = await createNewNoteFile(dir, "Plan", "body");
      const copy = await duplicateNoteFile(note);
      const original = parseGeneratedFilename(path.basename(note));
      const duplicate = parseGeneratedFilename(path.basename(copy));
      assert.equal(duplicate?.stamp, original?.stamp);
      assert.notEqual(duplicate?.id, original?.id);
      assert.equal(duplicate?.slug, "plan-copy");
      assert.equal(readdirSync(dir).length, 2);
    },
  ],
  [
    "a pin follows its note by id",
    async () => {
      await togglePin("/n/2026-01-01 0900 ab12 - old.md");
      const pins = await reconcilePins([
        "/n/2026-01-01 0900 ab12 - new-title.md",
        "/n/2026-01-01 0900 cd34 - same-minute.md",
      ]);
      assert.deepEqual([...pins].sort(), [
        "/n/2026-01-01 0900 ab12 - new-title.md",
      ]);
      for (const pin of pins) {
        await removePin(pin);
      }
    },
  ],
  [
    "a pin from before ids follows the migration's rename log, even with two notes from the same minute",
    async () => {
      const dir = freshDir();
      const a = path.join(dir, "2026-01-01 0900 - a.md");
      const b = path.join(dir, "2026-01-01 0900 - b.md");
      const newA = path.join(dir, "2026-01-01 0900 k3x9 - a.md");
      const newB = path.join(dir, "2026-01-01 0900 p0q1 - b.md");
      writeFileSync(
        path.join(dir, ".note-renames.jsonl"),
        `{"rename":["2026-01-01 0900 - a.md","2026-01-01 0900 k3x9 - a.md"]}\n` +
          `{"rename":["2026-01-01 0900 - b.md","2026-01-01 0900 p0q1 - b.md"]}\n` +
          `{"links":"done"}\n`,
      );
      await togglePin(a);
      await togglePin(b);
      const pins = await reconcilePins([newA, newB]);
      assert.deepEqual([...pins].sort(), [newA, newB].sort());
      for (const pin of pins) {
        await removePin(pin);
      }
    },
  ],
  [
    "a pin follows the log's note after a later rename, by the logged id",
    async () => {
      const dir = freshDir();
      writeFileSync(
        path.join(dir, ".note-renames.jsonl"),
        `{"rename":["2026-01-01 0900 - a.md","2026-01-01 0900 k3x9 - a.md"]}\n` +
          `{"links":"done"}\n`,
      );
      const gone = path.join(dir, "2026-01-01 0900 - a.md");
      const now = path.join(dir, "2026-01-01 0900 k3x9 - renamed-since.md");
      await togglePin(gone);
      const pins = await reconcilePins([now]);
      assert.deepEqual([...pins], [now]);
      await removePin(now);
    },
  ],
  [
    "without a rename log, a pin from before ids is not guessed by timestamp",
    async () => {
      const dir = freshDir();
      const gone = path.join(dir, "2026-01-01 0900 - old.md");
      const other = path.join(dir, "2026-01-01 0900 k3x9 - new-title.md");
      await togglePin(gone);
      const pins = await reconcilePins([other]);
      assert.deepEqual([...pins], [gone]);
      await removePin(gone);
    },
  ],
  [
    "the title is the first line with its markdown stripped",
    async () => {
      assert.equal(firstLineTitle("## Hello **world**\nmore"), "Hello world");
      assert.equal(firstLineTitle("hello\n"), "hello");
      assert.equal(firstLineTitle("- [ ] buy milk"), "buy milk");
      assert.equal(firstLineTitle("1. first"), "first");
      assert.equal(firstLineTitle("| quoted _words_"), "quoted words");
      assert.equal(firstLineTitle("> folded"), "folded");
      assert.equal(firstLineTitle("!> boxed"), "boxed");
      assert.equal(firstLineTitle("| > ## Deep"), "Deep");
      assert.equal(firstLineTitle(">text"), ">text");
      assert.equal(firstLineTitle(">> two"), ">> two");
      assert.equal(firstLineTitle("\n```\ncode\n```\nafter"), "code");
      assert.equal(
        firstLineTitle("see [the manual](https://x.y)"),
        "see the manual",
      );
      assert.equal(firstLineTitle("\n\n"), undefined);
      assert.equal(firstLineTitle("a".repeat(100))?.length, 80);
      assert.equal(
        firstLineTitle("![diagram](image.png) here"),
        "diagram here",
      );
      const emoji = firstLineTitle("👍🏽".repeat(90)) ?? "";
      assert.equal([...new Intl.Segmenter().segment(emoji)].length, 80);
      assert.equal(emoji, "👍🏽".repeat(80));
      assert.equal(
        parseTitleFromContentOrFilename(
          "/n/2026-01-01 0900 - x.md",
          "plain first line",
        ),
        "plain first line",
      );
      assert.equal(
        parseTitleFromContentOrFilename("/n/2026-01-01 0900 - my-note.md", ""),
        "My Note",
      );
    },
  ],
  [
    "parses tasks with any bullet, nesting and case",
    async () => {
      const dir = freshDir();
      writeFileSync(
        path.join(dir, "a.md"),
        "# A\n\n- [ ] one\n* [X] two\n  + [ ] nested\n- not a task\n",
      );
      const tasks = await listTasks(dir);
      assert.deepEqual(
        tasks.map((t) => [t.text, t.done, t.occurrence]),
        [
          ["one", false, 0],
          ["two", true, 0],
          ["nested", false, 0],
        ],
      );
      assert.equal(tasks[0].noteTitle, "A");
    },
  ],
  [
    "toggles in place and keeps the bullet style",
    async () => {
      const dir = freshDir();
      const note = path.join(dir, "a.md");
      writeFileSync(note, "- [ ] one\n* [x] two\n");
      const [one, two] = await listTasks(dir);
      await setTaskDone(one, true);
      await setTaskDone(two, false);
      assert.equal(readFileSync(note, "utf8"), "- [x] one\n* [ ] two\n");
    },
  ],
  [
    "falls back to the same occurrence when lines shift",
    async () => {
      const dir = freshDir();
      const note = path.join(dir, "a.md");
      writeFileSync(note, "- [ ] same\n- [ ] same\n- [ ] same\n");
      const tasks = await listTasks(dir);
      const second = tasks[1];
      assert.equal(second.occurrence, 1);
      // Two lines inserted above: index 1 now points at a non-task line.
      writeFileSync(note, "intro\nmore\n- [ ] same\n- [ ] same\n- [ ] same\n");
      await setTaskDone(second, true);
      assert.equal(
        readFileSync(note, "utf8"),
        "intro\nmore\n- [ ] same\n- [x] same\n- [ ] same\n",
      );
    },
  ],
  [
    "refuses when the task is gone",
    async () => {
      const dir = freshDir();
      const note = path.join(dir, "a.md");
      writeFileSync(note, "- [ ] one\n");
      const [one] = await listTasks(dir);
      writeFileSync(note, "- [ ] something else\n");
      await assert.rejects(setTaskDone(one, true), /note changed/);
    },
  ],
  [
    "keeps CRLF files CRLF on toggle and append",
    async () => {
      const dir = freshDir();
      const note = path.join(dir, "a.md");
      writeFileSync(note, "- [ ] one\r\n- [ ] two\r\n");
      const [one] = await listTasks(dir);
      await setTaskDone(one, true);
      assert.equal(readFileSync(note, "utf8"), "- [x] one\r\n- [ ] two\r\n");

      const daily = path.join(dir, getDailyFilename());
      writeFileSync(daily, "# today\r\n");
      await appendTaskToDaily(dir, "x");
      await appendDailyEntry(dir, "y");
      const text = readFileSync(daily, "utf8");
      assert.ok(
        !/[^\r]\n/.test(text),
        `mixed endings: ${JSON.stringify(text)}`,
      );
      assert.match(text, /- \[ \] x\r\n- \d\d:\d\d y\r\n$/);
    },
  ],
  [
    "collapses multi-line capture into one task",
    async () => {
      assert.equal(
        formatTaskLine("  buy\n\n  milk  \r\nand eggs"),
        "- [ ] buy milk and eggs",
      );
      const dir = freshDir();
      const daily = await appendTaskToDaily(dir, "line one\nline two");
      const tasks = await listTasks(dir);
      assert.deepEqual(
        tasks.map((t) => t.text),
        ["line one line two"],
      );
      assert.match(
        readFileSync(daily, "utf8"),
        /^# \d{4}-\d{2}-\d{2}\n\n- \[ \] line one line two\n$/,
      );
    },
  ],
  [
    "rename never lands on an existing file",
    async () => {
      const dir = freshDir();
      const created = await createNewNoteFile(dir, "First", "body");
      const prefix = path.basename(created).slice(0, 20);
      const taken = path.join(dir, `${prefix} - second.md`);
      writeFileSync(taken, "# Second\n\nkeep me\n");

      const renamed = await renameNoteFromTitleIfNeeded(created, "Second");
      // A rename never changes the id: the clash suffixes the slug.
      assert.equal(path.basename(renamed), `${prefix} - second-2.md`);
      assert.equal(readFileSync(taken, "utf8"), "# Second\n\nkeep me\n");
      assert.match(readFileSync(renamed, "utf8"), /^# First/);
      assert.throws(() => readFileSync(created), /ENOENT/);
    },
  ],
  [
    "repeated saves with an unchanged title keep a clash-suffixed path",
    async () => {
      const dir = freshDir();
      const created = await createNewNoteFile(dir, "First", "body");
      const prefix = path.basename(created).slice(0, 20);
      writeFileSync(path.join(dir, `${prefix} - second.md`), "# Second\n");
      const renamed = await renameNoteFromTitleIfNeeded(created, "Second");
      assert.equal(path.basename(renamed), `${prefix} - second-2.md`);
      assert.equal(
        await renameNoteFromTitleIfNeeded(renamed, "Second"),
        renamed,
      );
      assert.equal(
        await renameNoteFromTitleIfNeeded(renamed, "Second"),
        renamed,
      );
    },
  ],
  [
    "a deleted note's id is retired and never drawn again, nor a logged one",
    async () => {
      const dir = freshDir();
      writeFileSync(
        path.join(dir, ".note-renames.jsonl"),
        `{"rename":["2026-01-01 0900 - a.md","2026-01-01 0900 bbbb - a.md"]}\n` +
          `{"links":"done"}\n`,
      );
      writeFileSync(path.join(dir, "2026-01-02 0900 aaaa - here.md"), "x");
      await retireNoteId(path.join(dir, "2026-01-03 0900 cccc - gone.md"));
      await retireNoteId(path.join(dir, "groceries.md"));
      assert.deepEqual([...(await usedNoteIds(dir))].sort(), [
        "aaaa",
        "bbbb",
        "cccc",
      ]);
      const log = await readNoteLog(dir);
      assert.deepEqual(log?.retiredIDs, ["cccc"]);
      assert.equal(
        log?.renames["2026-01-01 0900 - a.md"],
        "2026-01-01 0900 bbbb - a.md",
      );
      assert.equal(log?.linksRewritten, true);
    },
  ],
  [
    '"Plan 2" renamed "Plan" becomes plan when free, stays plan-2 when not',
    async () => {
      const dir = freshDir();
      const note = await createNewNoteFile(dir, "Plan 2", "body");
      const prefix = path.basename(note).slice(0, 20);
      assert.equal(path.basename(note), `${prefix} - plan-2.md`);
      const renamed = await renameNoteFromTitleIfNeeded(note, "Plan");
      assert.equal(path.basename(renamed), `${prefix} - plan.md`);

      const other = await createNewNoteFile(dir, "Plan 2", "body");
      const otherPrefix = path.basename(other).slice(0, 20);
      writeFileSync(path.join(dir, `${otherPrefix} - plan.md`), "# Plan\n");
      assert.equal(await renameNoteFromTitleIfNeeded(other, "Plan"), other);
      assert.equal(await renameNoteFromTitleIfNeeded(other, "Plan"), other);
    },
  ],
  [
    "the shared log fixture folds the same as in Swift",
    async () => {
      const dir = freshDir();
      writeFileSync(
        path.join(dir, ".note-renames.jsonl"),
        readFileSync(path.join(__dirname, "../test/note-log.jsonl")),
      );
      const log = await readNoteLog(dir);
      assert.deepEqual(log?.renames, {
        "2026-01-01 0900 - a.md": "2026-01-01 0900 k3x9 - a.md",
      });
      assert.deepEqual(log?.retiredIDs, ["cccc", "dddd"]);
      assert.equal(log?.linksRewritten, true);
      await appendNoteLog(dir, [{ retire: "eeee" }]);
      assert.deepEqual((await readNoteLog(dir))?.retiredIDs, [
        "cccc",
        "dddd",
        "eeee",
      ]);
    },
  ],
  [
    "the links state follows line order: a later pending wins over an earlier done",
    async () => {
      const dir = freshDir();
      await appendNoteLog(dir, [{ links: "done" }, { links: "pending" }]);
      assert.equal((await readNoteLog(dir))?.linksRewritten, false);
      await appendNoteLog(dir, [{ links: "done" }]);
      assert.equal((await readNoteLog(dir))?.linksRewritten, true);
      await appendNoteLog(dir, [
        { rename: ["x.md", "y.md"] },
        { links: "pending" },
      ]);
      assert.equal((await readNoteLog(dir))?.linksRewritten, false);
    },
  ],
  [
    "two writers appending at once lose nothing",
    async () => {
      const dir = freshDir();
      await Promise.all(
        Array.from({ length: 200 }, (_, i) =>
          appendNoteLog(dir, [
            i % 2 === 0
              ? { retire: `r${String(i).padStart(3, "0")}` }
              : { rename: [`o${i}.md`, `n${i}.md`] },
          ]),
        ),
      );
      const log = await readNoteLog(dir);
      assert.equal(log?.retiredIDs?.length, 100);
      assert.equal(Object.keys(log?.renames ?? {}).length, 100);
    },
  ],
  [
    "pins toggle, move on rename and clear on delete",
    async () => {
      assert.equal(await togglePin("/a.md"), true);
      await movePin("/a.md", "/b.md");
      assert.deepEqual([...(await getPinnedPaths())], ["/b.md"]);
      await removePin("/b.md");
      assert.equal((await getPinnedPaths()).size, 0);
      assert.equal(await togglePin("/a.md"), true);
      assert.equal(await togglePin("/a.md"), false);
    },
  ],
];

(async () => {
  let failed = 0;
  for (const [name, run] of cases) {
    try {
      await run();
      console.log(`ok   ${name}`);
    } catch (error) {
      failed += 1;
      console.log(`FAIL ${name}`);
      console.log(error instanceof Error ? error.stack : error);
    }
  }
  console.log(`${cases.length - failed}/${cases.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
})();
