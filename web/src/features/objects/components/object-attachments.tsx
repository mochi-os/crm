// Mochi CRMs: Object attachment display and management
// Copyright Alistair Cunningham 2026

import { useState, useRef } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Download, Loader2, Paperclip, Trash2, Upload } from "lucide-react";
import {
  Button,
  ConfirmDialog,
  getAppPath,
  formatFileSize,
  isImage,
  getFileIcon,
  ImageLightbox,
  getErrorMessage,
  toast,
  type LightboxMedia,
} from "@mochi/common";
import crmsApi from "@/api/crms";
import type { Attachment } from "@/types";

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
  const [lightboxIndex, setLightboxIndex] = useState(-1);
  const [deleteTarget, setDeleteTarget] = useState<Attachment | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const queryClient = useQueryClient();

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
      toast.error(getErrorMessage(error, "Failed to upload attachment"));
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
      toast.error(getErrorMessage(error, "Failed to delete attachment"));
    },
  });

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = e.target.files;
    if (files && files.length > 0) {
      uploadMutation.mutate(Array.from(files));
    }
    // Reset so the same files can be selected again
    e.target.value = "";
  };

  const basePath = `${getAppPath()}/${crmId}/-/attachments/`;
  const attachments = data || [];
  const images = attachments.filter((a) => isImage(a.type));
  const files = attachments.filter((a) => !isImage(a.type));

  const lightboxMedia: LightboxMedia[] = images.map((img) => ({
    id: img.id,
    name: img.name,
    url: `${basePath}${img.id}`,
    type: "image",
  }));

  if (isLoading) {
    return (
      <div className="grid grid-cols-[120px_1fr] gap-4 items-start">
        <label className="text-sm font-medium text-muted-foreground pt-2 flex items-center gap-1.5">
          <Paperclip className="size-3.5" />
          Files
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
        Files
      </label>
      <div className="space-y-2 pt-1">
        {images.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {images.map((img, i) => (
              <div key={img.id} className="group relative">
                <button
                  type="button"
                  className="overflow-hidden rounded"
                  onClick={() => setLightboxIndex(i)}
                >
                  <img
                    src={`${basePath}${img.id}/thumbnail`}
                    alt={img.name}
                    className="h-20 w-auto object-cover"
                  />
                </button>
                {!readOnly && (
                  <button
                    type="button"
                    className="absolute -top-1.5 -right-1.5 hidden group-hover:flex size-5 items-center justify-center rounded-full bg-destructive text-destructive-foreground shadow-sm"
                    onClick={() => setDeleteTarget(img)}
                  >
                    <Trash2 className="size-3" />
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
        {files.length > 0 && (
          <div className="space-y-1">
            {files.map((file) => {
              const FileIcon = getFileIcon(file.type);
              return (
                <div
                  key={file.id}
                  className="group flex items-center gap-1.5 text-xs"
                >
                  <a
                    href={`${basePath}${file.id}`}
                    download={file.name}
                    className="text-muted-foreground hover:text-foreground flex items-center gap-1.5"
                  >
                    <FileIcon className="size-3" />
                    <span>{file.name}</span>
                    <span className="text-muted-foreground">
                      ({formatFileSize(file.size)})
                    </span>
                    <Download className="size-3" />
                  </a>
                  {!readOnly && (
                    <button
                      type="button"
                      className="hidden group-hover:inline-flex text-muted-foreground hover:text-destructive"
                      onClick={() => setDeleteTarget(file)}
                    >
                      <Trash2 className="size-3" />
                    </button>
                  )}
                </div>
              );
            })}
          </div>
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
                <Loader2 className="size-3 mr-1.5 animate-spin" />
              ) : (
                <Upload className="size-3 mr-1.5" />
              )}
              Upload
            </Button>
          </>
        )}
      </div>

      <ImageLightbox
        images={lightboxMedia}
        currentIndex={lightboxIndex}
        open={lightboxIndex >= 0}
        onOpenChange={(open) => {
          if (!open) setLightboxIndex(-1);
        }}
        onIndexChange={setLightboxIndex}
      />

      <ConfirmDialog
        open={!!deleteTarget}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null);
        }}
        title="Delete attachment"
        desc={`Are you sure you want to delete "${deleteTarget?.name}"?`}
        confirmText="Delete"
        destructive
        isLoading={deleteMutation.isPending}
        handleConfirm={() => {
          if (deleteTarget) deleteMutation.mutate(deleteTarget.id);
        }}
      />
    </div>
  );
}
