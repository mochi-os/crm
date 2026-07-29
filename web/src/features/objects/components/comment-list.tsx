// Mochi CRMs: Threaded comment list component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useCallback, useEffect, useState, useRef } from "react";
import { useLingui } from '@lingui/react/macro'
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, MessageSquare, Paperclip, Send, X } from "lucide-react";
import {
  Button,
  EmptyState,
  toast,
  getErrorMessage,
  ListSkeleton,
  MentionTextarea,
  useAuthStore,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  textUnchanged,
  findCommentTextInTree,
  cn,
  useImageObjectUrls,
  removePendingFile,
  ComposerAttachments,
  SendShortcutHint,
  dropActiveClass,
  offlineBlocked,
  useComposerDrop,
  useDiscardGuard,
} from "@mochi/web";
import crmsApi from "@/api/crms";
import { CommentThread } from "./comment-thread";

interface CommentListProps {
  crmId: string;
  objectId: string;
  readOnly?: boolean;
}

export function CommentList({
  crmId,
  objectId,
  readOnly,
}: CommentListProps) {
  const { t } = useLingui()
  const [newComment, setNewComment] = useState("");
  const [newFiles, setNewFiles] = useState<File[]>([]);
  const [replyingTo, setReplyingTo] = useState<string | null>(null);
  const [replyDraft, setReplyDraft] = useState("");
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [createFailed, setCreateFailed] = useState(false);
  const [isSendingComment, setIsSendingComment] = useState(false);

  const addNewFiles = useCallback((incoming: File[]) => {
    setCreateFailed(false);
    setNewFiles((prev) => [...prev, ...incoming]);
  }, []);
  const newFileImageUrls = useImageObjectUrls(newFiles);

  useEffect(() => {
    setNewComment("");
    setNewFiles([]);
    setCreateFailed(false);
    setReplyingTo(null);
    setReplyDraft("");
  }, [objectId]);
  const queryClient = useQueryClient();
  const currentUserId = useAuthStore((s) => s.identity);

  const { data, isLoading } = useQuery({
    queryKey: ["comments", crmId, objectId],
    queryFn: async () => {
      const response = await crmsApi.listComments(crmId, objectId);
      return response.data;
    },
  });

  const { data: peopleData } = useQuery({
    queryKey: ["people", crmId],
    queryFn: async () => {
      const response = await crmsApi.listPeople(crmId);
      return response.data.people;
    },
    staleTime: 60000,
  });
  const people = peopleData ?? [];

  const createMutation = useMutation({
    mutationFn: async ({
      content,
      parent,
      files,
    }: {
      content: string;
      parent?: string;
      files?: File[];
    }) => {
      return crmsApi.createComment(
        crmId,
        objectId,
        content,
        parent,
        files,
      );
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["comments", crmId, objectId],
      });
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
    },
    onError: (err) => {
      toast.error(getErrorMessage(err, t`Failed to post comment`));
    },
  });

  const updateMutation = useMutation({
    mutationFn: async ({
      commentId,
      content,
    }: {
      commentId: string;
      content: string;
    }) => {
      return crmsApi.updateComment(
        crmId,
        objectId,
        commentId,
        content,
      );
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["comments", crmId, objectId],
      });
    },
    onError: (err) => {
      toast.error(getErrorMessage(err, t`Failed to update comment`));
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async (commentId: string) => {
      return crmsApi.deleteComment(crmId, objectId, commentId);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["comments", crmId, objectId],
      });
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
    },
    onError: (err) => {
      toast.error(getErrorMessage(err, t`Failed to delete comment`));
    },
  });

  const handleCreate = async () => {
    const trimmed = newComment.trim();
    if (!trimmed || isSendingComment || offlineBlocked()) return;
    setCreateFailed(false);
    setIsSendingComment(true);
    try {
      await createMutation.mutateAsync({
        content: trimmed,
        files: newFiles.length > 0 ? newFiles : undefined,
      });
      setNewComment("");
      setNewFiles([]);
    } catch {
      // The mutation already reported it; keep the draft and its attachments
      // staged so Retry sends the same comment again.
      setCreateFailed(true);
    } finally {
      setIsSendingComment(false);
    }
  };

  const handleReply = async (parentId: string, files?: File[]) => {
    const trimmed = replyDraft.trim();
    if (!trimmed) return;
    await createMutation.mutateAsync(
      { content: trimmed, parent: parentId, files },
    );
    setReplyingTo(null);
    setReplyDraft("");
  };

  const handleEdit = (commentId: string, content: string) => {
    const original = findCommentTextInTree(data?.comments ?? [], commentId, {
      getId: (c) => c.id,
      getText: (c) => c.content,
      getChildren: (c) => c.children,
    });
    if (original !== undefined && textUnchanged(content, original)) {
      return;
    }
    updateMutation.mutate({ commentId, content });
  };

  const handleDelete = (commentId: string) => {
    deleteMutation.mutate(commentId);
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files) {
      addNewFiles(Array.from(e.target.files));
    }
    e.target.value = "";
  };

  const { isDragActive, dropzoneProps } = useComposerDrop({
    onFiles: addNewFiles,
    disabled: isSendingComment,
  });

  // The page composer is always on screen, so there is nothing to close —
  // discarding clears it in place.
  const discardNewComment = useCallback(() => {
    setNewComment("");
    setNewFiles([]);
    setCreateFailed(false);
  }, []);

  const hasDraft = newComment.trim().length > 0 || newFiles.length > 0;

  const { requestClose, discardDialog } = useDiscardGuard({
    hasText: newComment.trim().length > 0,
    hasFiles: newFiles.length > 0,
    onDiscard: discardNewComment,
    locked: isSendingComment,
  });

  if (isLoading) {
    return (
      <ListSkeleton count={3} variant="simple" height="h-12" />
    );
  }

  const comments = data?.comments ?? [];

  return (
    <div className="space-y-4">
      {!readOnly && (
        <div
          className={cn("space-y-2", isDragActive && dropActiveClass)}
          {...dropzoneProps}
        >
          <MentionTextarea
            className="placeholder:text-muted-foreground disabled:cursor-not-allowed disabled:opacity-50"
            value={newComment}
            onValueChange={setNewComment}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                void handleCreate();
              } else if (e.key === "Escape") {
                requestClose();
              }
            }}
            placeholder={t`Add a comment...`}
            rows={3}
            disabled={isSendingComment}
            people={people}
          />
          <ComposerAttachments
            files={newFiles}
            previewUrls={newFileImageUrls}
            state={
              isSendingComment ? "uploading" : createFailed ? "error" : "idle"
            }
            onRemove={(file) =>
              setNewFiles((prev) => removePendingFile(prev, file))
            }
            onRetry={() => void handleCreate()}
          />
          <div className="flex items-center justify-end gap-2">
            <SendShortcutHint />
            <input
              ref={fileInputRef}
              type="file"
              multiple
              onChange={handleFileSelect}
              className="hidden"
            />
            <Tooltip>
              <TooltipTrigger asChild>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="size-8"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={isSendingComment}
                  aria-label={t`Attach comment files`}
                >
                  <Paperclip className="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>{t`Attach comment files`}</TooltipContent>
            </Tooltip>
            {hasDraft && (
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="size-8"
                    onClick={requestClose}
                    disabled={isSendingComment}
                    aria-label={t`Cancel comment`}
                  >
                    <X className="size-4" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>{t`Cancel comment`}</TooltipContent>
              </Tooltip>
            )}
            <Tooltip>
              <TooltipTrigger asChild>
                <Button
                  type="button"
                  size="icon"
                  className="size-8"
                  disabled={!newComment.trim() || isSendingComment}
                  onClick={() => void handleCreate()}
                  aria-label={t`Submit comment`}
                >
                  {isSendingComment ? (
                    <Loader2 className="size-4 animate-spin" />
                  ) : (
                    <Send className="size-4" />
                  )}
                </Button>
              </TooltipTrigger>
              <TooltipContent>{t`Submit comment`}</TooltipContent>
            </Tooltip>
          </div>
          {discardDialog}
        </div>
      )}

      {comments.length === 0 ? (
        <EmptyState
          icon={MessageSquare}
          title={t`No comments yet`}
          description={t`Start the discussion by adding the first comment.`}
          className="py-4"
        />
      ) : (
        <div className="space-y-1">
          {comments.map((comment) => (
            <CommentThread
              key={comment.id}
              comment={comment}
              crmId={crmId}
              currentUserId={currentUserId}
              people={people}
              readOnly={!!readOnly}
              replyingTo={replyingTo}
              replyDraft={replyDraft}
              onStartReply={(id) => {
                setReplyingTo(id);
                const selected = window.getSelection()?.toString().trim();
                if (selected) {
                  const quoted = selected.split("\n").map((line) => `> ${line}`).join("\n") + "\n\n";
                  setReplyDraft(quoted);
                } else {
                  setReplyDraft("");
                }
              }}
              onCancelReply={() => {
                setReplyingTo(null);
                setReplyDraft("");
              }}
              onReplyDraftChange={setReplyDraft}
              onSubmitReply={handleReply}
              onEdit={handleEdit}
              onDelete={handleDelete}
            />
          ))}
        </div>
      )}
    </div>
  );
}
