/// Cloud boundary for OneBill's local-first synchronization.
///
/// The concrete Supabase implementation is added only after the team supplies
/// its project configuration. Repositories must continue to save locally when
/// this gateway is unavailable.
abstract interface class SyncGateway {
  Future<SyncBatchResult> push(List<SyncOperationPayload> operations);
  Future<List<SyncOperationPayload>> pull({
    required String accountId,
    required DateTime changedSince,
  });
}

class SyncOperationPayload {
  const SyncOperationPayload({
    required this.operationId,
    required this.businessId,
    required this.entityType,
    required this.entityId,
    required this.operationType,
    required this.payloadJson,
    required this.occurredAt,
  });

  final String operationId;
  final String? businessId;
  final String entityType;
  final String entityId;
  final String operationType;
  final String payloadJson;
  final DateTime occurredAt;
}

class SyncBatchResult {
  const SyncBatchResult({
    required this.acknowledgedOperationIds,
    required this.conflicts,
  });
  final Set<String> acknowledgedOperationIds;
  final List<SyncConflict> conflicts;
}

class SyncConflict {
  const SyncConflict({required this.operationId, required this.reason});
  final String operationId;
  final String reason;
}
