// Mochi CRMs: Recursive threaded comment component
// Copyright Alistair Cunningham 2026

import { useCallback, useState } from "react";
import { Trans } from '@lingui/react/macro'
import { Loader2, MoreHorizontal, Pencil, Reply, Send, Trash2, X, Paperclip } from "lucide-react";
import {
  Button,
  CommentTreeLayout,
  ConfirmDialog,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  EntityAvatar,
  useFormat,
  MentionTextarea,
  renderMentions,
  useImageObjectUrls,
  getAppPath,
} from "@mochi/web";
import type { Comment } from "@/types";
import { CommentAttachments } from "./comment-attachments";

interface Person {
  id: string;
  name: string;
}

interface CommentThreadProps {
  comment: Comment;
  crmId: string;
  currentUserId?: string;
  readOnly: boolean;
  replyingTo: string | null;
  replyDraft: string;
  onStartReply: (commentId: string) => void;
  onCancelReply: () => void;
  onReplyDraftChange: (value: string) => void;
  onSubmitReply: (commentId: string, files?: File[]) => void | Promise<void>;
  onEdit: (commentId: string, content: string) => void;
  onDelete: (commentId: string) => void;
  people?: Person[];
  depth?: number;
}

export function CommentThread({
  comment,
  crmId,
  currentUserId,
  readOnly,
  replyingTo,
  replyDraft,
  onStartReply,
  onCancelReply,
  onReplyDraftChange,
  onSubmitReply,
  onEdit,
  onDelete,
  people = [],
  depth = 0,
}: CommentThreadProps) {
  const { formatTimestamp } = useFormat();
  const [collapsed, setCollapsed] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editBody, setEditBody] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [replyFiles, setReplyFiles] = useState<File[]>([]);
  const [isSubmittingReply, setIsSubmittingReply] = useState(false);
  const replyPreviewUrls = useImageObjectUrls(replyFiles);
  const replyFileRef = { current: null as HTMLInputElement | null };

  const handleSubmitReply = useCallback(async () => {
    if (isSubmittingReply) return;
    setIsSubmittingReply(true);
    try {
      await onSubmitReply(
        comment.id,
        replyFiles.length > 0 ? replyFiles : undefined,
      );
      setReplyFiles([]);
    } finally {
      setIsSubmittingReply(false);
    }
  }, [isSubmittingReply, onSubmitReply, comment.id, replyFiles]);

  const isReplying = replyingTo === comment.id;
  const hasChildren = comment.children && comment.children.length > 0;
  const canEdit = currentUserId === comment.author && !readOnly;
  const canDelete = currentUserId === comment.author && !readOnly;

  const getTotalDescendants = (c: Comment): number => {
    if (!c.children) return 0;
    return (
      c.children.length +
      c.children.reduce((acc, child) => acc + getTotalDescendants(child), 0)
    );
  };
  const totalDescendants = getTotalDescendants(comment);

  const timestamp = formatTimestamp(comment.created);

  const assetUrl = (slot: string) =>
    `${getAppPath()}/${crmId}/-/comment/${comment.id}/asset/${slot}`;
  const avatar = (
    <EntityAvatar
      src={assetUrl("avatar")}
      styleUrl={assetUrl("style")}
      seed={comment.author}
      name={comment.name || comment.author}
      size="xs"
      className="z-10"
    />
  );

  const collapsedContent = (
    <div className="flex h-5 items-center gap-2 py-0.5 text-xs select-none">
      <span className="text-muted-foreground font-medium">
        {comment.name || comment.author}
      </span>
      <span className="text-muted-foreground">&middot;</span>
      <span className="text-muted-foreground">{timestamp}</span>
      <button
        type="button"
        onClick={() => setCollapsed(false)}
        className="text-primary ml-2 flex cursor-pointer items-center gap-1 hover:underline"
      >
        {totalDescendants > 0 ? (
          <span>
            {totalDescendants === 1
              ? "1 reply"
              : `+${totalDescendants} more replies`}
          </span>
        ) : (
          <span className="text-muted-foreground italic">(expand)</span>
        )}
      </button>
    </div>
  );

  const content = (
    <div className="space-y-1.5">
      <div className="group/row">
        <div className="flex h-5 items-center gap-2 text-xs">
          <span className="text-foreground font-medium">
            {comment.name || comment.author}
          </span>
          <span className="text-muted-foreground">&middot;</span>
          <span className="text-muted-foreground">{timestamp}</span>
          {comment.edited > 0 && (
            <span className="text-muted-foreground italic">(edited)</span>
          )}
        </div>

        {editing ? (
          <div className="space-y-2">
            <MentionTextarea
              value={editBody}
              onValueChange={setEditBody}
              rows={3}
              autoFocus
              people={people}
            />
            <div className="flex justify-end gap-2">
              <Button
                variant="outline"
                size="sm"
                className="h-7 text-xs"
                onClick={() => setEditing(false)}
              >
                <Trans>Cancel</Trans>
              </Button>
              <Button
                size="sm"
                className="h-7 text-xs"
                disabled={!editBody.trim()}
                onClick={() => {
                  onEdit(comment.id, editBody.trim());
                  setEditing(false);
                }}
              >
                <Trans>Save</Trans>
              </Button>
            </div>
          </div>
        ) : (
          <p className="text-foreground text-sm leading-relaxed whitespace-pre-wrap">
            {renderMentions(comment.content)}
          </p>
        )}

        <CommentAttachments
          attachments={comment.attachments}
          crmId={crmId}
        />

        {!readOnly && (
          <div className="flex min-h-7 items-center gap-2 pt-0.5">
            {/* Desktop: hover-reveal inline actions */}
            <div className="pointer-events-none hidden items-center gap-1 opacity-0 transition-opacity group-hover/row:pointer-events-auto group-hover/row:opacity-100 md:flex">
              <button
                type="button"
                className="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs transition-colors"
                onClick={() => onStartReply(comment.id)}
              >
                <Reply className="size-3" />
                <span><Trans>Reply</Trans></span>
              </button>

              {canEdit && (
                <button
                  type="button"
                  className="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs transition-colors"
                  onClick={() => {
                    setEditing(true);
                    setEditBody(comment.content);
                  }}
                >
                  <Pencil className="size-3" />
                  <span><Trans>Edit</Trans></span>
                </button>
              )}

              {canDelete && (
                <button
                  type="button"
                  className="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs transition-colors"
                  onClick={() => setDeleting(true)}
                >
                  <Trash2 className="size-3" />
                  <span><Trans>Delete</Trans></span>
                </button>
              )}
            </div>

            {/* Mobile: always-visible dropdown */}
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button
                  type="button"
                  className="text-muted-foreground hover:bg-muted rounded-full p-1 transition-colors md:hidden"
                >
                  <MoreHorizontal className="size-4" />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start">
                <DropdownMenuItem onClick={() => onStartReply(comment.id)}>
                  <Reply className="mr-2 size-4" />
                  <Trans>Reply</Trans>
                </DropdownMenuItem>
                {canEdit && (
                  <DropdownMenuItem
                    onClick={() => {
                      setEditing(true);
                      setEditBody(comment.content);
                    }}
                  >
                    <Pencil className="mr-2 size-4" />
                    <Trans>Edit</Trans>
                  </DropdownMenuItem>
                )}
                {canDelete && (
                  <DropdownMenuItem
                    className="text-destructive focus:text-destructive"
                    onClick={() => setDeleting(true)}
                  >
                    <Trash2 className="mr-2 size-4" />
                    <Trans>Delete</Trans>
                  </DropdownMenuItem>
                )}
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        )}
      </div>

      {isReplying && (
        <div className="mt-2 space-y-2 border-t pt-2">
          <MentionTextarea
            placeholder={`Reply to ${comment.name || comment.author}...`}
            value={replyDraft}
            onValueChange={onReplyDraftChange}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                if (replyDraft.trim()) void handleSubmitReply();
              } else if (e.key === "Escape") {
                onCancelReply();
              }
            }}
            rows={2}
            autoFocus
            people={people}
          />
          {replyFiles.length > 0 && (
            <div className="flex flex-wrap gap-2">
              {replyFiles.map((file, i) => (
                <div
                  key={i}
                  className="bg-muted relative flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs"
                >
                  {file.type.startsWith("image/") && (
                    <img
                      src={replyPreviewUrls[i] ?? undefined}
                      alt={file.name}
                      className="h-8 w-8 rounded object-cover"
                    />
                  )}
                  <Paperclip className="text-muted-foreground size-3 shrink-0" />
                  <span className="max-w-40 truncate">{file.name}</span>
                  <button
                    type="button"
                    onClick={() =>
                      setReplyFiles((prev) => prev.filter((_, idx) => idx !== i))
                    }
                    className="text-muted-foreground hover:text-foreground ml-0.5"
                  >
                    <X className="size-3.5" />
                  </button>
                </div>
              ))}
            </div>
          )}
          <div className="flex items-center justify-end gap-2">
            <input
              ref={(el) => {
                replyFileRef.current = el;
              }}
              type="file"
              multiple
              onChange={(e) => {
                if (e.target.files) {
                  const f = Array.from(e.target.files);
                  setReplyFiles((prev) => [...prev, ...f]);
                }
                e.target.value = "";
              }}
              className="hidden"
            />
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="size-8"
              onClick={() => replyFileRef.current?.click()}
              disabled={isSubmittingReply}
              aria-label={"Attach reply files"}
              title={"Attach reply files"}
            >
              <Paperclip className="size-4" />
            </Button>
            <Button
              type="button"
              size="icon"
              variant="ghost"
              className="size-8"
              onClick={onCancelReply}
              disabled={isSubmittingReply}
              aria-label={"Cancel reply"}
              title={"Cancel reply"}
            >
              <X className="size-4" />
            </Button>
            <Button
              type="button"
              size="icon"
              className="size-8"
              disabled={!replyDraft.trim() || isSubmittingReply}
              onClick={() => void handleSubmitReply()}
              aria-label={"Submit reply"}
              title={"Submit reply"}
            >
              {isSubmittingReply ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}
            </Button>
          </div>
        </div>
      )}

      <ConfirmDialog
        open={deleting}
        onOpenChange={setDeleting}
        title={"Delete comment"}
        desc="Are you sure you want to delete this comment? This will also delete all replies."
        confirmText="Delete"
        destructive
        handleConfirm={() => {
          onDelete(comment.id);
          setDeleting(false);
        }}
      />
    </div>
  );

  const children = hasChildren ? (
    <>
      {comment.children.map((child) => (
        <CommentThread
          key={child.id}
          comment={child}
          crmId={crmId}
          currentUserId={currentUserId}
          readOnly={readOnly}
          replyingTo={replyingTo}
          replyDraft={replyDraft}
          onStartReply={onStartReply}
          onCancelReply={onCancelReply}
          onReplyDraftChange={onReplyDraftChange}
          onSubmitReply={onSubmitReply}
          onEdit={onEdit}
          onDelete={onDelete}
          people={people}
          depth={depth + 1}
        />
      ))}
    </>
  ) : null;

  return (
    <CommentTreeLayout
      depth={depth}
      isCollapsed={collapsed}
      onToggleCollapse={() => setCollapsed(!collapsed)}
      hasChildren={hasChildren}
      avatar={avatar}
      content={content}
      collapsedContent={collapsedContent}
    >
      {children}
    </CommentTreeLayout>
  );
}
