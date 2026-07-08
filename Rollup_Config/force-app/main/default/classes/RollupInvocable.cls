/**
 * RollupInvocable
 * Flow Invocable Action — entry point for real-time rollup recalculation.
 *
 * Routes based on rule Mode:
 *   Realtime  → RollupEngine.processForObject(..., 'Realtime')  — sync, in Flow tx
 *   Queueable → RollupQueueable  — async, fresh transaction, ~2-10s delay
 *   Scheduled → skipped here, handled by RollupBatch
 *
 * Deletes: run a separate Before-Delete flow that passes Is Delete = True.
 * Delete rules are processed synchronously (Realtime + Queueable inline) while
 * the records still exist, so RollupEngine can exclude them and recompute over
 * the surviving children.
 *
 * Source object is derived automatically from the Record ID —
 * admin only passes {!$Record.Id}, nothing else.
 *
 * Admin setup (create/update — one-time per child object):
 *   1. Flow Builder → New → Record-Triggered Flow on e.g. Opportunity
 *   2. Trigger: A record is created or updated (After Save)
 *   3. Add Action → search "Recalculate Rollups"
 *   4. Affected Record ID → {!$Record.Id}
 *   5. Activate
 *
 * Admin setup (delete — one-time per child object):
 *   1. Flow Builder → New → Record-Triggered Flow on the same object
 *   2. Trigger: A record is deleted
 *   3. Add Action → search "Recalculate Rollups"
 *   4. Affected Record ID → {!$Record.Id}
 *   5. Is Delete → {!$GlobalConstant.True}
 *   6. Activate
 */
public with sharing class RollupInvocable {

    public class Request {
        @InvocableVariable(
            label='Affected Record ID'
            description='ID of the child record that changed. Pass {!$Record.Id}. The object API name is detected automatically.'
            required=true)
        public Id affectedRecordId;

        @InvocableVariable(
            label='Is Delete'
            description='Set to True only in a Before-Delete flow. Leave blank/False for create or update.'
            required=false)
        public Boolean isDelete = false;
    }

    @InvocableMethod(
        label='Recalculate Rollups'
        description='Recalculates all active rollup rules for the child object and writes results to parent records. Use in a record-triggered Flow — just pass {!$Record.Id}.'
        category='Rollup Tool'
    )
    public static void recalculate(List<Request> requests) {
        if (requests == null || requests.isEmpty()) return;

        // Group child IDs by source object API name, and track whether any
        // request for that object is a delete. Object derived from the ID itself
        // — works for all standard and custom objects.
        Map<String, Set<Id>> byObject       = new Map<String, Set<Id>>();
        Map<String, Boolean> deleteByObject = new Map<String, Boolean>();

        for (Request req : requests) {
            if (req.affectedRecordId == null) continue;
            String srcObj = req.affectedRecordId.getSObjectType().getDescribe().getName();
            if (!byObject.containsKey(srcObj)) {
                byObject.put(srcObj, new Set<Id>());
                deleteByObject.put(srcObj, false);
            }
            byObject.get(srcObj).add(req.affectedRecordId);
            if (req.isDelete == true) deleteByObject.put(srcObj, true);
        }
        if (byObject.isEmpty()) return;

        for (String srcObj : byObject.keySet()) {
            Set<Id> childIds = byObject.get(srcObj);

            if (deleteByObject.get(srcObj) == true) {
                // Deletes must run synchronously inside the before-delete transaction,
                // while the records still exist, so we can exclude them and recompute
                // over survivors. Queueable is unsafe here: by the time an async job runs
                // post-commit the record is already gone, and the live-record resolution
                // in resolveParentIds returns empty. We process Realtime + Queueable rules
                // inline and leave Scheduled rules to the batch (respecting their opt-out).
                RollupEngine.processForObject(srcObj, childIds, 'Realtime',  true);
                RollupEngine.processForObject(srcObj, childIds, 'Queueable', true);
                continue;
            }

            // ── Create / update routing ──
            // Load all rules for this object to determine mode routing
            List<Rollup_Rule__c> allRules = RollupEngine.loadRules(srcObj, null);
            if (allRules.isEmpty()) continue;

            Boolean hasRealtime  = false;
            Boolean hasQueueable = false;
            for (Rollup_Rule__c rule : allRules) {
                if (rule.Mode__c == 'Realtime')  hasRealtime  = true;
                if (rule.Mode__c == 'Queueable') hasQueueable = true;
            }

            // Realtime — runs synchronously inside the Flow transaction
            if (hasRealtime) {
                RollupEngine.processForObject(srcObj, childIds, 'Realtime');
            }

            // Queueable — enqueue one async job per source object
            if (hasQueueable) {
                if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                    System.enqueueJob(new RollupQueueable(srcObj, childIds));
                } else {
                    // Queue full — fall back to sync rather than silently drop
                    RollupEngine.processForObject(srcObj, childIds, 'Queueable');
                }
            }
        }
    }
}