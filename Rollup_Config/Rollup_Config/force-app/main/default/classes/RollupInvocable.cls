/**
 * RollupInvocable
 * Flow Invocable Action — entry point for real-time rollup recalculation.
 *
 * Routes based on rule Mode:
 *   Realtime  → RollupEngine.processForObject(..., 'Realtime')  — sync, in Flow tx
 *   Queueable → RollupQueueable  — async, fresh transaction, ~2-10s delay
 *   Scheduled → skipped here, handled by RollupBatch
 *
 * Source object is derived automatically from the Record ID —
 * admin only passes {!$Record.Id}, nothing else.
 *
 * Admin setup (one-time per child object):
 *   1. Flow Builder → New → Record-Triggered Flow on e.g. Opportunity
 *   2. Trigger: A record is created or updated (After Save)
 *   3. Add Action → search "Recalculate Rollups"
 *   4. Affected Record ID → {!$Record.Id}
 *   5. Activate
 */
public with sharing class RollupInvocable {

    public class Request {
        @InvocableVariable(
            label='Affected Record ID'
            description='ID of the child record that changed. Pass {!$Record.Id}. The object API name is detected automatically.'
            required=true)
        public Id affectedRecordId;
    }

    @InvocableMethod(
        label='Recalculate Rollups'
        description='Recalculates all active rollup rules for the child object and writes results to parent records. Use in a record-triggered Flow — just pass {!$Record.Id}.'
        category='Rollup Tool'
    )
    public static void recalculate(List<Request> requests) {
        if (requests == null || requests.isEmpty()) return;

        // Group child IDs by source object API name
        // Derived from the ID itself — works for all standard and custom objects
        Map<String, Set<Id>> byObject = new Map<String, Set<Id>>();
        for (Request req : requests) {
            if (req.affectedRecordId == null) continue;
            String srcObj = req.affectedRecordId.getSObjectType().getDescribe().getName();
            if (!byObject.containsKey(srcObj)) byObject.put(srcObj, new Set<Id>());
            byObject.get(srcObj).add(req.affectedRecordId);
        }
        if (byObject.isEmpty()) return;

        for (String srcObj : byObject.keySet()) {
            Set<Id> childIds = byObject.get(srcObj);

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