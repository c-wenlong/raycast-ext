import {
  Action,
  ActionPanel,
  Form,
  Icon,
  Toast,
  showToast,
  useNavigation,
} from "@raycast/api";
import { useState } from "react";
import { errorMessage } from "../lib/daemon";
import {
  CATEGORIES,
  DEFAULT_PROFILE,
  ProfileDraft,
  ProfileEntry,
  ProfileErrors,
  ProfileSpec,
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
      <Form.TextArea
        id="apps"
        title="Extra Apps"
        placeholder={"com.apple.Music\ncom.spotify.client"}
        info={`One bundle id per line. Find an app's with: osascript -e 'id of app "Slack"'`}
        value={draft.apps}
        error={errors.apps}
        onChange={(value) => update("apps", value)}
      />
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
