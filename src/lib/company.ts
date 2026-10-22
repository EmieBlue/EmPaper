// Client companies: the words the owner sees for companies.branding_status.
// The database allows exactly these four values (companies_branding_status_check).

export const BRANDING_STATUSES = ['none', 'requested', 'pending_review', 'approved'] as const;
export type BrandingStatus = (typeof BRANDING_STATUSES)[number];

export const BRANDING_LABELS: Record<BrandingStatus, string> = {
  none: 'Not collected yet',
  requested: 'Link sent',
  pending_review: 'Waiting for your review',
  approved: 'Approved',
};

export function brandingLabel(value: unknown): string {
  return typeof value === 'string' && (BRANDING_STATUSES as readonly string[]).includes(value)
    ? BRANDING_LABELS[value as BrandingStatus]
    : 'Unknown';
}

export function activeLabel(isActive: unknown): string {
  return isActive === false ? 'Paused' : 'Active';
}
