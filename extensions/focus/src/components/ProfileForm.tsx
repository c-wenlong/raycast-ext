import {
  Action,
  ActionPanel,
  Form,
  Icon,
  Toast,
  getApplications,
  showToast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useMemo, useState } from "react";
import { errorMessage } from "../lib/daemon";
import {
  CATEGORIES,
  DEFAULT_PROFILE,
  ProfileDraft,
  ProfileEntry,
  ProfileErrors,
  ProfileSpec,
  InstalledApp,
  alignSelection,
  appPickerItems,
  draftFor,
  validateProfile,
} from "../lib/profiles";

// Add or edit one blocking profile. Saving writes config.json at once (the
// list that opened this does the write) and goes back to the list.

const MODE_HELP: Record<string, string> = {
  blocklist:
    "Blocks the apps and hosts of the chosen categories plus the extra ones below. Everything else stays open.",
  allowlist:
    "Blocks every app and host except the chosen categories and the extra ones below. Raycast, Finder, System Settings and the watched browsers are always allowed; their tabs are still filtered by host.",
};

export function ProfileForm(props: {
  // Null when adding a profile.
  entry: ProfileEntry | null;
  // Every profile name there is, "default" included, for the duplicate check.
  existingNames: string[];
  onSave: (
    originalName: string | null,
    name: string,
    spec: ProfileSpec,
  ) => Promise<void>;
}) {
  const { pop } = useNavigation();
  const originalName = props.entry?.name ?? null;
  const isDefault = originalName === DEFAULT_PROFILE;
  const [draft, setDraft] = useState<ProfileDraft>(() => draftFor(props.entry));
  const [errors, setErrors] = useState<ProfileErrors>({});
  const [isSaving, setIsSaving] = useState(false);
  // Installed apps for the Extra Apps picker; null until loaded. `appsLoad`
  // counts loads so "Reload Installed Apps" can run the lookup again after a
  // failure (or after installing an app) without closing the form.
  const [installed, setInstalled] = useState<InstalledApp[] | null>(null);
  const [appsLoad, setAppsLoad] = useState(0);
  const [appsFailed, setAppsFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setInstalled(null);
    getApplications()
      .then((apps) => {
        if (cancelled) return;
        setInstalled(apps);
        setAppsFailed(false);
      })
      .catch(async (error) => {
        if (cancelled) return;
        setInstalled([]);
        setAppsFailed(true);
        await showToast({
          style: Toast.Style.Failure,
          title: "Could not list installed apps",
          message: `${errorMessage(error)}. Use Reload Installed Apps (⌘R) to try again.`,
        });
      });
    return () => {
      cancelled = true;
    };
  }, [appsLoad]);

  // Rebuilt only when the installed list or the chosen apps change, not on
  // every keystroke in another field.
  const appItems = useMemo(
    () => appPickerItems(installed ?? [], draft.apps),
    [installed, draft.apps],
  );
  const appValue = useMemo(
    () => alignSelection(draft.apps, appItems),
    [draft.apps, appItems],
  );

  function update<K extends keyof ProfileDraft>(
    key: K,
    value: ProfileDraft[K],
  ) {
    setDraft((current) => ({ ...current, [key]: value }));
    if (errors[key]) setErrors((current) => ({ ...current, [key]: undefined }));
  }

  // Categories in the draft that the helper does not know (a hand edit):
  // shown so they can be removed.
  const unknownCategories = draft.categories.filter(
    (id) => !CATEGORIES.some((category) => category.id === id),
  );

  async function handleSubmit() {
    const result = validateProfile(draft, originalName, props.existingNames);
    if (!result.ok) {
      setErrors(result.errors);
      await showToast({
        style: Toast.Style.Failure,
        title: "Check the highlighted fields",
        message: Object.values(result.errors).filter(Boolean).join("; "),
      });
      return;
    }
    setIsSaving(true);
    try {
      await props.onSave(originalName, result.name, result.spec);
      pop();
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not save the profile",
        message: errorMessage(error),
      });
    } finally {
      setIsSaving(false);
    }
  }

  const title = props.entry
    ? `Edit Profile "${props.entry.name}"`
    : "New Profile";

  return (
    <Form
      navigationTitle={title}
      isLoading={isSaving}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Profile"
            icon={Icon.CheckCircle}
            onSubmit={handleSubmit}
          />
          <Action
            title="Reload Installed Apps"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={() => setAppsLoad((n) => n + 1)}
          />
        </ActionPanel>
      }
    >
      {isDefault ? (
        <Form.Description
          title="Name"
          text="default (used by every calendar without a profile of its own; cannot be renamed)"
        />
      ) : (
        <Form.TextField
          id="name"
          title="Name"
          placeholder="deep"
          value={draft.name}
          error={errors.name}
          onChange={(value) => update("name", value)}
        />
      )}
      {props.entry?.malformed ? (
        <Form.Description
          title="Note"
          text={`The saved entry was not readable (${props.entry.malformed}). Saving replaces it.`}
        />
      ) : null}
      <Form.Dropdown
        id="mode"
        title="Mode"
        value={draft.mode}
        error={errors.mode}
        onChange={(value) => update("mode", value)}
      >
        <Form.Dropdown.Item
          value="blocklist"
          title="Blocklist"
          icon={Icon.XMarkCircle}
        />
        <Form.Dropdown.Item
          value="allowlist"
          title="Allowlist"
          icon={Icon.CheckCircle}
        />
      </Form.Dropdown>
      <Form.Description text={MODE_HELP[draft.mode] ?? ""} />
      <Form.TagPicker
        id="categories"
        title="Categories"
        value={draft.categories}
        error={errors.categories}
        onChange={(value) => update("categories", value)}
      >
        {CATEGORIES.map((category) => (
          <Form.TagPicker.Item
            key={category.id}
            value={category.id}
            title={category.title}
          />
        ))}
        {unknownCategories.map((id) => (
          <Form.TagPicker.Item
            key={id}
            value={id}
            title={`Unknown: ${id}`}
            icon={Icon.Warning}
          />
        ))}
      </Form.TagPicker>
      <Form.TagPicker
        id="apps"
        title="Extra Apps"
        placeholder={
          installed === null
            ? "Loading installed apps…"
            : appsFailed
              ? "Installed apps did not load: press ⌘R to try again"
              : "Pick apps"
        }
        info="Installed apps, on top of the categories. An app saved by hand that is not installed shows as Not installed so it can be removed."
        value={appValue}
        error={errors.apps}
        onChange={(value) => update("apps", value)}
      >
        {appItems.map((item) => (
          <Form.TagPicker.Item
            key={item.value}
            value={item.value}
            title={item.title}
            icon={item.path ? { fileIcon: item.path } : Icon.Warning}
          />
        ))}
      </Form.TagPicker>
      <Form.TextArea
        id="hosts"
        title="Extra Hosts"
        placeholder={"9gag.com\nimgur.com"}
        info="One host per line, lowercase, without https:// or a path. A host also covers its subdomains, so youtube.com covers m.youtube.com; a leading www. is dropped."
        value={draft.hosts}
        error={errors.hosts}
        onChange={(value) => update("hosts", value)}
      />
    </Form>
  );
}
