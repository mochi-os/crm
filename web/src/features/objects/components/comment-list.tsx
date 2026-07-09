// Mochi CRMs: Threaded comment list component
// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useState, useRef } from "react";
import { useLingui } from '@lingui/react/macro'
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { MessageSquare, Paperclip, Send, X } from "lucide-react";
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
  Attachment,
  AttachmentGroup,
  AttachmentMedia,
  AttachmentContent,
  AttachmentTitle,
  AttachmentDescription,
  AttachmentActions,
  AttachmentAction,
  useFormat,
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
  const queryClient = useQueryClient();
  const currentUserId = useAuthStore((s) => s.identity);
  const { formatFileSize } = useFormat();

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

  const handleCreate = () => {
    const trimmed = newComment.trim();
    if (!trimmed) return;
    createMutation.mutate(
      { content: trimmed, files: newFiles.length > 0 ? newFiles : undefined },
      {
        onSuccess: () => {
          setNewComment("");
          setNewFiles([]);
        },
      },
    );
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
      const selected = Array.from(e.target.files);
      setNewFiles((prev) => [...prev, ...selected]);
    }
    e.target.value = "";
  };

  if (isLoading) {
    return (
      <ListSkeleton count={3} variant="simple" height="h-12" />
    );
  }

  const comments = data?.comments ?? [];

  return (
    <div className="space-y-4">
      {!readOnly && (
        <div className="space-y-2">
          <MentionTextarea
            value={newComment}
            onValueChange={setNewComment}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                handleCreate();
              }
            }}
            placeholder={t`Add a comment...`}
            rows={3}
            people={people}
          />
          {newFiles.length > 0 && (
            <AttachmentGroup>
              {newFiles.map((file, i) => {
                const isImage = file.type.startsWith("image/");
                return (
                  <Attachment key={i} state="uploading" size="sm">
                    <AttachmentMedia variant={isImage ? "image" : "icon"}>
                      <Paperclip />
                    </AttachmentMedia>
                    <AttachmentContent>
                      <AttachmentTitle>{file.name}</AttachmentTitle>
                      <AttachmentDescription>
                        {formatFileSize(file.size)}
                      </AttachmentDescription>
                    </AttachmentContent>
                    <AttachmentActions>
                      <AttachmentAction
                        onClick={() =>
                          setNewFiles((prev) => prev.filter((_, idx) => idx !== i))
                        }
                        aria-label={t`Remove`}
                      >
                        <X className="size-4" />
                      </AttachmentAction>
                    </AttachmentActions>
                  </Attachment>
                );
              })}
            </AttachmentGroup>
          )}
          <div className="flex items-center justify-end gap-2">
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
                  aria-label={t`Attach comment files`}
                >
                  <Paperclip className="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>{t`Attach comment files`}</TooltipContent>
            </Tooltip>
            <Tooltip>
              <TooltipTrigger asChild>
                <Button
                  type="button"
                  size="icon"
                  className="size-8"
                  disabled={!newComment.trim() || createMutation.isPending}
                  onClick={handleCreate}
                  aria-label={t`Submit comment`}
                >
                  <Send className="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>{t`Submit comment`}</TooltipContent>
            </Tooltip>
          </div>
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
