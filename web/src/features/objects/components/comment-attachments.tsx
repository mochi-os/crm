// Mochi CRMs: Comment attachment display
// Copyright Alistair Cunningham 2026

import { useState } from "react";
import { Download } from "lucide-react";
import {
  getAppPath,
  formatFileSize,
  isImage,
  getFileIcon,
  ImageLightbox,
  type LightboxMedia,
} from "@mochi/common";
import type { CommentAttachment } from "@/types";

interface CommentAttachmentsProps {
  attachments: CommentAttachment[];
  crmId: string;
}

export function CommentAttachments({
  attachments,
  crmId,
}: CommentAttachmentsProps) {
  const [lightboxIndex, setLightboxIndex] = useState(-1);

  if (!attachments || attachments.length === 0) return null;

  const basePath = `${getAppPath()}/${crmId}/-/attachments/`;
  const images = attachments.filter((a) => isImage(a.type));
  const files = attachments.filter((a) => !isImage(a.type));

  const lightboxMedia: LightboxMedia[] = images.map((img) => ({
    id: img.id,
    name: img.name,
    url: `${basePath}${img.id}`,
    type: "image",
  }));

  return (
    <div className="mt-1 space-y-1">
      {images.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {images.map((img, i) => (
            <button
              key={img.id}
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
          ))}
        </div>
      )}
      {files.length > 0 && (
        <div className="space-y-0.5">
          {files.map((file) => {
            const FileIcon = getFileIcon(file.type);
            return (
              <a
                key={file.id}
                href={`${basePath}${file.id}`}
                download={file.name}
                className="text-muted-foreground hover:text-foreground flex items-center gap-1.5 text-xs"
              >
                <FileIcon className="size-3" />
                <span>{file.name}</span>
                <span className="text-muted-foreground">
                  ({formatFileSize(file.size)})
                </span>
                <Download className="size-3" />
              </a>
            );
          })}
        </div>
      )}
      <ImageLightbox
        images={lightboxMedia}
        currentIndex={lightboxIndex}
        open={lightboxIndex >= 0}
        onOpenChange={(open) => {
          if (!open) setLightboxIndex(-1);
        }}
        onIndexChange={setLightboxIndex}
      />
    </div>
  );
}
