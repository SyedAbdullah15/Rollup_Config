/**
 * RollupBatch
 * Scheduled/on-demand batch job for historical recalculation.
 * Processes ALL child records for a given source object —
 * not just recently changed ones.
 *
 * Triggered by:
 *   - "Recalculate All" button in rollupConfigurator LWC
 *   - Scheduled job (future)
 *
 * Strategy:
 *   - Queries all child records in chunks (batch size 200)
 *   - Per chunk: groups unique parent IDs and calls RollupEngine
 *   - Engine handles 1 SOQL + 1 DML per lookup group as usual
 *
 * Safe for large orgs — batch chunks prevent heap/CPU limits.
 */
public with sharing class RollupBatch implements Database.Batchable<SObject>, Database.Stateful {

    private final String sourceObjectApi;
    private final String lookupField;
    private Integer      processedChunks = 0;
    private Integer      errors          = 0;

    public RollupBatch(String sourceObjectApi, String lookupField) {
        this.sourceObjectApi = sourceObjectApi;
        this.lookupField     = lookupField;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Start — build the query to fetch all child records
    // ─────────────────────────────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        // Fetch all child records where the lookup field is populated
        // Only Id and the lookup field needed — engine fetches all other fields itself
        String soql = 'SELECT Id, ' + lookupField
                    + ' FROM ' + sourceObjectApi
                    + ' WHERE ' + lookupField + ' != null'
                    + ' ORDER BY ' + lookupField;
        return Database.getQueryLocator(soql);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Execute — process each chunk
    // ─────────────────────────────────────────────────────────────────────────

    public void execute(Database.BatchableContext ctx, List<SObject> scope) {
        try {
            // Collect child IDs from this chunk
            Set<Id> childIds = new Set<Id>();
            for (SObject rec : scope) {
                childIds.add(rec.Id);
            }

            // Engine handles everything:
            // groups by lookup field, fetches all children of resolved parents,
            // filters in memory, aggregates, writes results
            RollupEngine.processForObject(sourceObjectApi, childIds, null);
            processedChunks++;
        } catch (Exception e) {
            errors++;
            System.debug('RollupBatch error in chunk: ' + e.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Finish — update the config record with last run timestamp
    // ─────────────────────────────────────────────────────────────────────────

    public void finish(Database.BatchableContext ctx) {
        System.debug('RollupBatch complete. Chunks: ' + processedChunks + ' Errors: ' + errors);
    }
}