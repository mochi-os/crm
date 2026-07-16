// Mochi CRMs: Object attachment display and management
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useState, useRef } from "react";
import { Trans, useLingui } from '@lingui/react/macro'
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Download, Loader2, Paperclip, Trash2, Upload } from "lucide-react";
import {
  Attachment,
  AttachmentAction,
  AttachmentActions,
  AttachmentContent,
  AttachmentDescription,
  AttachmentGroup,
  AttachmentMedia,
  AttachmentTitle,
  AttachmentTrigger,
  AttachmentGallery,
  Button,
  ConfirmDialog,
  getAppPath,
  useFormat,
  isImage,
  getFileIcon,
  getErrorMessage,
  authenticatedUrl,
  toast,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@mochi/web";
import crmsApi from "@/api/crms";
import type { Attachment as AttachmentData } from "@/types";

interface ObjectAttachmentsProps {
  crmId: string;
  objectId: string;
  readOnly: boolean;
}

export function ObjectAttachments({
  crmId,
  objectId,
  readOnly,
}: ObjectAttachmentsProps) {
  const { t } = useLingui()
  const [deleteTarget, setDeleteTarget] = useState<AttachmentData | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const queryClient = useQueryClient();
  const { formatFileSize } = useFormat();

  const { data, isLoading } = useQuery({
    queryKey: ["attachments", crmId, objectId],
    queryFn: async () => {
      const response = await crmsApi.listAttachments(crmId, objectId);
      return response.data.attachments;
    },
  });

  const uploadMutation = useMutation({
    mutationFn: async (files: File[]) => {
      return crmsApi.uploadAttachments(crmId, objectId, files);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["attachments", crmId, objectId],
      });
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to upload attachment`));
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async (attachmentId: string) => {
      return crmsApi.deleteAttachment(crmId, objectId, attachmentId);
    },
    onSuccess: () => {
      setDeleteTarget(null);
      queryClient.invalidateQueries({
        queryKey: ["attachments", crmId, objectId],
      });
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to delete attachment`));
    },
  });

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = e.target.files;
    if (files && files.length > 0) {
      uploadMutation.mutate(Array.from(files));
    }
    e.target.value = "";
  };

  const basePath = `${getAppPath()}/${crmId}/-/attachments/`;
  const attUrl = (id: string, suffix = "") => authenticatedUrl(`${basePath}${id}${suffix}`);
  const attachments: AttachmentData[] = data || [];
  const images = attachments.filter((a) => isImage(a.type));
  const files = attachments.filter((a) => !isImage(a.type));

  if (isLoading) {
    return (
      <div className="grid grid-cols-[120px_1fr] gap-4 items-start">
        <label className="text-sm font-medium text-muted-foreground pt-2 flex items-center gap-1.5">
          <Paperclip className="size-3.5" />
          <Trans>Files</Trans>
        </label>
        <div className="flex items-center gap-2 pt-2">
          <Loader2 className="size-4 animate-spin text-muted-foreground" />
        </div>
      </div>
    );
  }

  if (attachments.length === 0 && readOnly) {
    return null;
  }

  return (
    <div className="grid grid-cols-[120px_1fr] gap-4 items-start">
      <label className="text-sm font-medium text-muted-foreground pt-2 flex items-center gap-1.5">
        <Paperclip className="size-3.5" />
        <Trans>Files</Trans>
      </label>
      <div className="space-y-2 pt-1">
        {images.length > 0 && (
          <AttachmentGallery
            attachments={images}
            getUrl={(att) => attUrl(att.id)}
            getThumbnailUrl={(att) => attUrl(att.id, "/thumbnail")}
            rowHeight={80}
            hideFiles
            renderMediaOverlay={
              readOnly
                ? undefined
                : (att) => (
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <button
                          type="button"
                          aria-label={t`Delete`}
                          className="absolute -top-1.5 -right-1.5 hidden group-hover/item:flex size-5 items-center justify-center rounded-full bg-destructive text-destructive-foreground shadow-sm"
                          onClick={(e) => {
                            e.stopPropagation()
                            setDeleteTarget(att as AttachmentData)
                          }}
                        >
                          <Trash2 className="size-3" />
                        </button>
                      </TooltipTrigger>
                      <TooltipContent>{t`Delete`}</TooltipContent>
                    </Tooltip>
                  )
            }
          />
        )}
        {files.length > 0 && (
          <AttachmentGroup>
            {files.map((file) => {
              const FileIcon = getFileIcon(file.type);
              return (
                <Attachment key={file.id} size="sm">
                  <AttachmentTrigger asChild>
                    <a href={attUrl(file.id)} download={file.name}>
                      <span className="sr-only">{file.name}</span>
                    </a>
                  </AttachmentTrigger>
                  <AttachmentMedia>
                    <FileIcon />
                  </AttachmentMedia>
                  <AttachmentContent>
                    <AttachmentTitle>{file.name}</AttachmentTitle>
                    <AttachmentDescription>
                      {formatFileSize(file.size)}
                    </AttachmentDescription>
                  </AttachmentContent>
                  <AttachmentActions>
                    <AttachmentAction
                      asChild
                      variant="ghost"
                      size="icon"
                      className="opacity-0 group-hover/attachment:opacity-100 focus-within:opacity-100 text-muted-foreground hover:text-foreground"
                    >
                      <a href={attUrl(file.id)} download={file.name}>
                        <Download className="size-3" />
                        <span className="sr-only">
                          <Trans>Download</Trans>
                        </span>
                      </a>
                    </AttachmentAction>
                    {!readOnly && (
                      <AttachmentAction
                        variant="ghost"
                        size="icon"
                        className="opacity-0 group-hover/attachment:opacity-100 focus-within:opacity-100 text-muted-foreground hover:text-destructive"
                        onClick={() => setDeleteTarget(file)}
                      >
                        <Trash2 className="size-3" />
                        <span className="sr-only">
                          <Trans>Delete</Trans>
                        </span>
                      </AttachmentAction>
                    )}
                  </AttachmentActions>
                </Attachment>
              );
            })}
          </AttachmentGroup>
        )}
        {!readOnly && (
          <>
            <input
              ref={fileInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={handleFileChange}
            />
            <Button
              variant="outline"
              size="sm"
              className="h-7 text-xs"
              onClick={() => fileInputRef.current?.click()}
              disabled={uploadMutation.isPending}
            >
              {uploadMutation.isPending ? (
                <Loader2 className="size-3 me-1.5 animate-spin" />
              ) : (
                <Upload className="size-3 me-1.5" />
              )}
              <Trans>Upload</Trans>
            </Button>
          </>
        )}
      </div>

      <ConfirmDialog
        open={!!deleteTarget}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null);
        }}
        title={t`Delete attachment`}
        desc={t`Are you sure you want to delete "${deleteTarget?.name}"?`}
        confirmText={t`Delete`}
        destructive
        isLoading={deleteMutation.isPending}
        handleConfirm={() => {
          if (deleteTarget) deleteMutation.mutate(deleteTarget.id);
        }}
      />
    </div>
  );
}
