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
import { FinishResult, Session, errorMessage, getDaemon } from "../lib/daemon";
import { stars } from "../lib/time";

// Finish from Raycast: the fallback for the helper's native end sheet (the
// menu bar and the sheet are the main way to finish), and the only way when
// the helper runs without its UI. The helper records why the session ended
// (timer or stop), so no reason is sent.

const RATINGS = [5, 4, 3, 2, 1];

function finishMessage(result: FinishResult, logCalendarName: string | null) {
  if (result.logSkipped) return "Not logged: the session had no calendar";
  if (!result.logPending) {
    return logCalendarName ? `Logged to ${logCalendarName}` : "Logged";
  }
  return logCalendarName
    ? `The log event is waiting for ${logCalendarName}`
    : "Pick a log calendar in Focus Settings to log it";
}

export function FinishSessionForm(props: {
  session: Session;
  // From config.json, for the toast; the helper decides where the log goes.
  logCalendarName: string | null;
  onFinished: (result: FinishResult) => void;
}) {
  const { pop } = useNavigation();
  const [isSubmitting, setIsSubmitting] = useState(false);

  async function handleSubmit(values: { rating: string; note: string }) {
    setIsSubmitting(true);
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Finishing session",
    });
    try {
      const result = await getDaemon().finish({
        rating: Number(values.rating),
        note: values.note,
      });
      toast.style = Toast.Style.Success;
      toast.title = `Finished: ${result.session.goal}`;
      toast.message = finishMessage(result, props.logCalendarName);
      props.onFinished(result);
      pop();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not finish the session";
      toast.message = errorMessage(error);
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <Form
      navigationTitle="Finish Session"
      isLoading={isSubmitting}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Finish Session"
            icon={Icon.CheckCircle}
            onSubmit={handleSubmit}
          />
        </ActionPanel>
      }
    >
      <Form.Description title="Session" text={props.session.goal} />
      <Form.Dropdown id="rating" title="Rating" defaultValue="3">
        {RATINGS.map((rating) => (
          <Form.Dropdown.Item
            key={rating}
            value={String(rating)}
            title={stars(rating)}
          />
        ))}
      </Form.Dropdown>
      <Form.TextField
        id="note"
        title="Note"
        placeholder="One line on how it went"
      />
    </Form>
  );
}
