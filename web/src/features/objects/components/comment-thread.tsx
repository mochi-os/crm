// Mochi CRMs: Recursive threaded comment component
// Copyright Alistair Cunningham 2026

import { useState } from "react";
import { Pencil, Reply, Send, Trash2, X, Paperclip } from "lucide-react";
import {
  Button,
  CommentTreeLayout,
  ConfirmDialog,
  formatTimestamp,
} from "@mochi/common";
import type { Comment } from "@/types";
import { CommentAttachments } from "./comment-attachments";

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
  onSubmitReply: (commentId: string, files?: File[]) => void;
  onEdit: (commentId: string, content: string) => void;
  onDelete: (commentId: string) => void;
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
  depth = 0,
}: CommentThreadProps) {
  const [collapsed, setCollapsed] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editBody, setEditBody] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [replyFiles, setReplyFiles] = useState<File[]>([]);
  const replyFileRef = { current: null as HTMLInputElement | null };

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

  const avatar = (
    <div className="bg-primary text-primary-foreground z-10 flex size-5 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold">
      {(comment.name || comment.author).charAt(0).toUpperCase()}
    </div>
  );

  const collapsedContent = (
    <div className="flex h-5 items-center gap-2 py-0.5 text-xs select-none">
      <span className="text-muted-foreground font-medium">
        {comment.name || comment.author}
      </span>
      <span className="text-muted-foreground">&middot;</span>
      <span className="text-muted-foreground">{timestamp}</span>
      <button
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
            <textarea
              value={editBody}
              onChange={(e) => setEditBody(e.target.value)}
              className="border-input bg-background min-h-16 w-full resize-none rounded-lg border px-3 py-2 text-sm"
              rows={3}
              autoFocus
            />
            <div className="flex justify-end gap-2">
              <Button
                variant="outline"
                size="sm"
                className="h-7 text-xs"
                onClick={() => setEditing(false)}
              >
                Cancel
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
                Save
              </Button>
            </div>
          </div>
        ) : (
          <p className="text-foreground text-sm leading-relaxed whitespace-pre-wrap">
            {comment.content}
          </p>
        )}

        <CommentAttachments
          attachments={comment.attachments}
          crmId={crmId}
        />

        {!readOnly && (
          <div className="flex min-h-[28px] items-center gap-2 pt-0.5">
            <div className="pointer-events-none flex items-center gap-1 opacity-0 transition-opacity group-hover/row:pointer-events-auto group-hover/row:opacity-100">
              <button
                type="button"
                className="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs transition-colors"
                onClick={() => onStartReply(comment.id)}
              >
                <Reply className="size-3" />
                <span>Reply</span>
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
                  <span>Edit</span>
                </button>
              )}

              {canDelete && (
                <button
                  type="button"
                  className="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs transition-colors"
                  onClick={() => setDeleting(true)}
                >
                  <Trash2 className="size-3" />
                  <span>Delete</span>
                </button>
              )}
            </div>
          </div>
        )}
      </div>

      {isReplying && (
        <div className="mt-2 space-y-2 border-t pt-2">
          <textarea
            placeholder={`Reply to ${comment.name || comment.author}...`}
            value={replyDraft}
            onChange={(e) => onReplyDraftChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                if (replyDraft.trim())
                  onSubmitReply(
                    comment.id,
                    replyFiles.length > 0 ? replyFiles : undefined,
                  );
              } else if (e.key === "Escape") {
                onCancelReply();
              }
            }}
            className="border-input bg-background min-h-16 w-full resize-none rounded-lg border px-3 py-2 text-sm"
            rows={2}
            autoFocus
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
                      src={URL.createObjectURL(file)}
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
            >
              <Paperclip className="size-4" />
            </Button>
            <Button
              type="button"
              size="icon"
              variant="ghost"
              className="size-8"
              onClick={onCancelReply}
            >
              <X className="size-4" />
            </Button>
            <Button
              type="button"
              size="icon"
              className="size-8"
              disabled={!replyDraft.trim()}
              onClick={() =>
                onSubmitReply(
                  comment.id,
                  replyFiles.length > 0 ? replyFiles : undefined,
                )
              }
            >
              <Send className="size-4" />
            </Button>
          </div>
        </div>
      )}

      <ConfirmDialog
        open={deleting}
        onOpenChange={setDeleting}
        title="Delete comment"
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
