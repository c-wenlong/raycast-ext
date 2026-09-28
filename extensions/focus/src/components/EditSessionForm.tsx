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
import {
  NO_RATING,
  RecentSession,
  editSessionRequest,
  editSessionValues,
  errorMessage,
  getDaemon,
  updateToastText,
} from "../lib/daemon";
import { stars } from "../lib/time";

// Edit Session from Focus Stats: a finished session's rating and note, with
// the finish form's dropdown and note field. The helper rewrites the log
// event's notes to match when the event is still its own.

const RATINGS = [5, 4, 3, 2, 1];

export function EditSessionForm(props: {
  session: RecentSession;
  onUpdated: () => void;
}) {
  const { pop } = useNavigation();
  const [isSubmitting, setIsSubmitting] = useState(false);
  const initial = editSessionValues(props.session);

  async function handleSubmit(values: { rating: string; note: string }) {
    setIsSubmitting(true);
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Updating session",
    });
    try {
      const result = await getDaemon().updateSession(
        props.session.id,
        editSessionRequest(values),
      );
      const text = updateToastText(result);
      toast.style = Toast.Style.Success;
      toast.title = text.title;
      toast.message = text.message;
      pop();
      props.onUpdated();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not update the session";
      toast.message = errorMessage(error);
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <Form
      navigationTitle="Edit Session"
      isLoading={isSubmitting}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Session"
            icon={Icon.Pencil}
            onSubmit={handleSubmit}
          />
        </ActionPanel>
      }
    >
      <Form.Description title="Session" text={props.session.goal} />
      <Form.Dropdown id="rating" title="Rating" defaultValue={initial.rating}>
        {RATINGS.map((rating) => (
          <Form.Dropdown.Item
            key={rating}
            value={String(rating)}
            title={stars(rating)}
          />
        ))}
        <Form.Dropdown.Item value={NO_RATING} title="No rating" />
      </Form.Dropdown>
      <Form.TextField
        id="note"
        title="Note"
        placeholder="One line on how it went"
        defaultValue={initial.note}
      />
    </Form>
  );
}
