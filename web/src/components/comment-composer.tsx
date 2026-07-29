// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useCallback, useEffect, useRef, useState } from "react";
import { t } from "@lingui/core/macro";
import { Trans } from "@lingui/react/macro";
import {
  Attachment,
  AttachmentAction,
  AttachmentActions,
  AttachmentContent,
  AttachmentDescription,
  AttachmentGroup,
  AttachmentMedia,
  AttachmentTitle,
  ConfirmDialog,
  cn,
  pendingFileKey,
  toast,
  useFormat,
} from "@mochi/web";
import { Paperclip, RotateCcw, X } from "lucide-react";

/**
 * Lifecycle of the files a composer is holding.
 *
 * `idle` — picked, not sent yet. `uploading` — in flight. `error` — the send
 * failed and the files are still staged so the user can retry.
 */
export type ComposerFileState = "idle" | "uploading" | "error";

const isMacPlatform = () =>
  typeof navigator !== "undefined" &&
  /Mac|iPhone|iPad|iPod/.test(navigator.userAgent);

const COARSE_POINTER = "(hover: none) and (pointer: coarse)";

/**
 * False on phones and tablets, where there is no key to press and the
 * shortcut chip is just noise. Reads the query up front so the hint never
 * flashes in before it is hidden.
 */
function useHasKeyboard(): boolean {
  const [hasKeyboard, setHasKeyboard] = useState(
    () =>
      typeof window === "undefined" ||
      !window.matchMedia(COARSE_POINTER).matches,
  );

  useEffect(() => {
    const query = window.matchMedia(COARSE_POINTER);
    const apply = () => setHasKeyboard(!query.matches);
    apply();
    query.addEventListener("change", apply);
    return () => query.removeEventListener("change", apply);
  }, []);

  return hasKeyboard;
}

/**
 * Send shortcut chip. Decorative only — the Send button already carries the
 * accessible name, so this stays out of the accessibility tree (and out of the
 * message catalogs).
 */
export function SendShortcutHint({ className }: { className?: string }) {
  const hasKeyboard = useHasKeyboard();
  if (!hasKeyboard) return null;

  return (
    <span
      aria-hidden
      className={cn(
        "text-muted-foreground/70 me-auto font-mono text-[11px] leading-none select-none",
        className,
      )}
    >
      {isMacPlatform() ? "⌘" : "Ctrl"}
      <span className="ms-0.5">{"↵"}</span>
    </span>
  );
}

/**
 * Fails a send before it starts when the browser knows it has no network.
 *
 * Without this the request just sits there spinning — uploads deliberately
 * carry no timeout — and only completes once the connection comes back.
 * Returns true when the send was blocked and already reported.
 */
export function offlineBlocked(): boolean {
  if (typeof navigator === "undefined" || navigator.onLine !== false) {
    return false;
  }
  toast.error(t`Please check your internet connection and try again.`);
  return true;
}

const carriesFiles = (transfer: DataTransfer | null) =>
  Array.from(transfer?.types ?? []).includes("Files");

/**
 * Drag-and-drop and paste-to-attach for a composer.
 *
 * Spread `dropzoneProps` on the element that wraps the text field and the
 * attachment list. Paste rides on the same element: it bubbles up from the
 * focused textarea, and the event is only swallowed when the clipboard
 * actually carries files, so pasting text is untouched.
 */
export function useComposerDrop({
  onFiles,
  disabled = false,
}: {
  onFiles: (files: File[]) => void;
  disabled?: boolean;
}) {
  // Nested children fire dragleave as the pointer crosses them, so track the
  // enter/leave depth instead of toggling on the first leave.
  const depth = useRef(0);
  const [isDragActive, setIsDragActive] = useState(false);

  // The composer claims the drop even while it is busy. Letting it through
  // would hand the file to the browser, which navigates away from the page and
  // takes the draft with it.
  const onDragEnter = useCallback(
    (e: React.DragEvent) => {
      if (!carriesFiles(e.dataTransfer)) return;
      e.preventDefault();
      if (disabled) return;
      depth.current += 1;
      setIsDragActive(true);
    },
    [disabled],
  );

  const onDragOver = useCallback(
    (e: React.DragEvent) => {
      if (!carriesFiles(e.dataTransfer)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = disabled ? "none" : "copy";
    },
    [disabled],
  );

  const onDragLeave = useCallback(() => {
    if (disabled) return;
    depth.current = Math.max(0, depth.current - 1);
    if (depth.current === 0) setIsDragActive(false);
  }, [disabled]);

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      if (!carriesFiles(e.dataTransfer)) return;
      e.preventDefault();
      depth.current = 0;
      setIsDragActive(false);
      if (disabled) return;
      const dropped = Array.from(e.dataTransfer.files);
      if (dropped.length > 0) onFiles(dropped);
    },
    [disabled, onFiles],
  );

  const onPaste = useCallback(
    (e: React.ClipboardEvent) => {
      if (disabled) return;
      const pasted = Array.from(e.clipboardData?.files ?? []);
      if (pasted.length === 0) return;
      e.preventDefault();
      onFiles(pasted);
    },
    [disabled, onFiles],
  );

  return {
    isDragActive,
    dropzoneProps: { onDragEnter, onDragOver, onDragLeave, onDrop, onPaste },
  };
}

/** Outline shown while files are hovering over a composer. */
export const dropActiveClass =
  "outline-primary/50 bg-primary/5 rounded-lg outline-2 outline-offset-4 outline-dashed";

interface ComposerAttachmentsProps {
  files: File[];
  previewUrls: (string | null)[];
  state?: ComposerFileState;
  onRemove: (file: File) => void;
  onRetry?: () => void;
}

/**
 * Staged attachment list for a composer. Renders nothing when empty, so the
 * caller does not have to guard it.
 */
export function ComposerAttachments({
  files,
  previewUrls,
  state = "idle",
  onRemove,
  onRetry,
}: ComposerAttachmentsProps) {
  const { formatFileSize } = useFormat();
  if (files.length === 0) return null;

  return (
    <div className="space-y-1">
      <AttachmentGroup>
        {files.map((file, i) => {
          const isImage = file.type.startsWith("image/");
          const previewUrl = previewUrls[i];
          return (
            <Attachment key={pendingFileKey(file)} state={state} size="sm">
              <AttachmentMedia variant={isImage ? "image" : "icon"}>
                {isImage && previewUrl ? (
                  <img src={previewUrl} alt={file.name} draggable={false} />
                ) : (
                  <Paperclip />
                )}
              </AttachmentMedia>
              <AttachmentContent>
                <AttachmentTitle>{file.name}</AttachmentTitle>
                <AttachmentDescription>
                  {formatFileSize(file.size)}
                </AttachmentDescription>
              </AttachmentContent>
              {state !== "uploading" && (
                <AttachmentActions>
                  <AttachmentAction
                    onClick={() => onRemove(file)}
                    aria-label={t`Remove`}
                  >
                    <X className="size-4" />
                  </AttachmentAction>
                </AttachmentActions>
              )}
            </Attachment>
          );
        })}
      </AttachmentGroup>
      {state === "error" && onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="text-destructive hover:bg-destructive/10 inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs transition-colors active:translate-y-px"
        >
          <RotateCcw className="size-3" />
          <Trans>Retry</Trans>
        </button>
      )}
    </div>
  );
}

/**
 * Guards closing a composer that still holds a draft.
 *
 * `requestClose` closes straight away when there is nothing to lose, asks
 * first when there is, and does nothing at all while a send is in flight —
 * which is what stops Escape from throwing away a comment mid-request.
 */
export function useDiscardGuard({
  hasText,
  hasFiles,
  onDiscard,
  locked = false,
}: {
  hasText: boolean;
  hasFiles: boolean;
  onDiscard: () => void;
  locked?: boolean;
}) {
  const [confirming, setConfirming] = useState(false);
  const hasContent = hasText || hasFiles;

  const requestClose = useCallback(() => {
    if (locked) return;
    if (hasContent) {
      setConfirming(true);
      return;
    }
    onDiscard();
  }, [hasContent, locked, onDiscard]);

  // Name only what is actually about to go, so the warning matches the form.
  const desc =
    hasText && hasFiles
      ? t`Your text and attachments will be lost.`
      : hasFiles
        ? t`Your attachments will be lost.`
        : t`Your text will be lost.`;

  const discardDialog = (
    <ConfirmDialog
      open={confirming}
      onOpenChange={setConfirming}
      title={t`Discard draft?`}
      desc={desc}
      confirmText={t`Discard`}
      destructive
      handleConfirm={() => {
        setConfirming(false);
        onDiscard();
      }}
    />
  );

  return { requestClose, discardDialog };
}
