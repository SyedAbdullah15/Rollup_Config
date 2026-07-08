/**
 * RollupQueueable
 * Runs Queueable-mode rollup rules asynchronously in a fresh Apex transaction.
 * Enqueued by RollupInvocable. One job per source object.
 *
 * With the optimised engine:
 *   10 rules, 1 lookup field  → 1 SOQL + 1 DML
 *   10 rules, 2 lookup fields → 2 SOQLs + 2 DMLs
 */
public class RollupQueueable implements Queueable {

    private final String  sourceObjectApi;
    private final Set<Id> affectedChildIds;

    public RollupQueueable(String sourceObjectApi, Set<Id> affectedChildIds) {
        this.sourceObjectApi  = sourceObjectApi;
        this.affectedChildIds = affectedChildIds;
    }

    public void execute(QueueableContext ctx) {
        if (String.isBlank(sourceObjectApi) || affectedChildIds == null || affectedChildIds.isEmpty()) return;
        RollupEngine.processForObject(sourceObjectApi, affectedChildIds, 'Queueable');
    }
}