abstract final class NotificationCategories {
  static const invoiceCreated = 'invoice_created';
  static const invoiceSentShared = 'invoice_sent_shared';
  static const invoiceDueSoon = 'invoice_due_soon';
  static const invoiceDueToday = 'invoice_due_today';
  static const invoiceOverdue = 'invoice_overdue';

  static const paymentReceived = 'payment_received';
  static const partialPayment = 'partial_payment';
  static const paymentReminder = 'payment_reminder';
  static const paymentOverdue = 'payment_overdue';

  static const customerOutstanding = 'customer_outstanding';
  static const customerFullyPaid = 'customer_fully_paid';

  static const dailySummary = 'daily_summary';
  static const weeklySummary = 'weekly_summary';
  static const monthlySummary = 'monthly_summary';

  static const syncCompleted = 'sync_completed';
  static const syncFailed = 'sync_failed';

  static const importantAlerts = 'important_alerts';
  static const announcements = 'announcements';

  static const Map<String, bool> defaults = {
    invoiceCreated: true,
    invoiceSentShared: true,
    invoiceDueSoon: true,
    invoiceDueToday: true,
    invoiceOverdue: true,
    paymentReceived: true,
    partialPayment: true,
    paymentReminder: true,
    paymentOverdue: true,
    customerOutstanding: true,
    customerFullyPaid: true,
    dailySummary: true,
    weeklySummary: true,
    monthlySummary: true,
    syncCompleted: false,
    syncFailed: true,
    importantAlerts: true,
    announcements: false,
  };

  static const Map<String, String> labels = {
    invoiceCreated: 'Invoice created',
    invoiceSentShared: 'Invoice sent/shared',
    invoiceDueSoon: 'Invoice due soon',
    invoiceDueToday: 'Invoice due today',
    invoiceOverdue: 'Invoice overdue',
    paymentReceived: 'Payment received',
    partialPayment: 'Partial payment',
    paymentReminder: 'Payment reminder',
    paymentOverdue: 'Payment overdue',
    customerOutstanding: 'Customer outstanding',
    customerFullyPaid: 'Customer fully paid',
    dailySummary: 'Daily summary',
    weeklySummary: 'Weekly summary',
    monthlySummary: 'Monthly summary',
    syncCompleted: 'Sync completed',
    syncFailed: 'Sync failed',
    importantAlerts: 'Important OneBill alerts',
    announcements: 'Announcements',
  };
}

abstract final class NotificationChannels {
  static const reminders = 'payment_invoice_reminders';
  static const payments = 'payment_activity';
  static const summaries = 'business_summaries';
  static const sync = 'sync_backup';
  static const alerts = 'important_alerts';
}

abstract final class NotificationActionKeys {
  static const viewInvoice = 'action_view_invoice';
  static const remindLater = 'action_remind_later';
  static const viewCustomer = 'action_view_customer';
  static const viewPayment = 'action_view_payment';
  static const viewSync = 'action_view_sync';
  static const retrySync = 'action_retry_sync';
  static const shareInvoice = 'action_share_invoice';
  static const viewSummary = 'action_view_summary';
}

