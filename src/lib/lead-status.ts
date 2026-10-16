// Lead pipeline: the values stored in leads.status and the plain-English words the owner sees.
// The database allows exactly these five values (leads_status_check).

export const LEAD_STATUSES = ['new', 'contacted', 'qualified', 'converted', 'lost'] as const;
export type LeadStatus = (typeof LEAD_STATUSES)[number];

export const STATUS_LABELS: Record<LeadStatus, string> = {
  new: 'New',
  contacted: "I've contacted them",
  qualified: 'Good fit',
  converted: 'Became a client',
  lost: 'Not going ahead',
};

export const INTEREST_LABELS: Record<string, string> = {
  pay_letters: 'Pay & Letters',
  time_off_holidays: 'Time Off & Holidays',
  people_directory: 'People Directory',
  my_info: 'My Info',
  company_files_announcements: 'Company Files & Announcements',
  inbox_instant_answers: 'Inbox & Instant Answers',
};

export function isLeadStatus(value: unknown): value is LeadStatus {
  return typeof value === 'string' && (LEAD_STATUSES as readonly string[]).includes(value);
}

export function statusLabel(value: unknown): string {
  return isLeadStatus(value) ? STATUS_LABELS[value] : 'Unknown';
}

// Unknown interest keys are shown as-is so a new form option never disappears from the owner's view.
export function interestLabel(key: string): string {
  return INTEREST_LABELS[key] ?? key;
}

export function countByStatus(rows: ReadonlyArray<{ status?: unknown }>): Record<LeadStatus, number> {
  const counts = { new: 0, contacted: 0, qualified: 0, converted: 0, lost: 0 } as Record<LeadStatus, number>;
  for (const row of rows) if (isLeadStatus(row.status)) counts[row.status]++;
  return counts;
}

// Answer to "Do you have a logo?" on the demo form (leads.logo_status; empty = not answered).
export const LOGO_LABELS: Record<string, string> = {
  yes: 'Yes, they have a logo',
  no: 'No logo yet',
  unsure: 'Not sure',
};

export function logoLabel(value: unknown): string {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(LOGO_LABELS, value)
    ? LOGO_LABELS[value]
    : 'Not answered';
}
