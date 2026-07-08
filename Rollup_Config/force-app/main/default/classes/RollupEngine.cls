/**
 * RollupEngine
 * Optimised bulk calculation engine.
 *
 * Strategy per group of rules sharing the same lookup field:
 *   1. Resolve parent IDs from the affected child IDs (1 SOQL)
 *   2. Collect ALL fields needed across every rule in the group
 *   3. ONE SOQL fetching ALL children of those parents (not just affected ones)
 *   4. Per rule — filter records in-memory via RollupFilterBuilder.matches()
 *   5. Per rule — aggregate the filtered set in Apex
 *   6. ONE DML to update all parent records with all target fields at once
 *
 * Result: 2 SOQLs + 1 DML per unique lookup field, regardless of rule count.
 *
 * Called by: RollupInvocable (Realtime), RollupQueueable (Queueable), RollupBatch.
 */
public with sharing class RollupEngine {

    // ─────────────────────────────────────────────────────────────────────────
    //  Public entry points
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Overload with no mode filter — processes all modes (used by batch and tests).
     */
    public static void processForObject(String sourceObjectApi, Set<Id> affectedChildIds) {
        processForObject(sourceObjectApi, affectedChildIds, null, false);
    }

    /**
     * Process all active rules for a source object filtered by mode.
     * mode = 'Realtime'  → called synchronously inside the Flow transaction
     * mode = 'Queueable' → called from RollupQueueable in its own transaction
     * mode = null        → process all modes (used by batch)
     *
     * Delegates to the 4-arg overload with isDelete = false (create/update path).
     */
    public static void processForObject(String sourceObjectApi, Set<Id> affectedChildIds, String mode) {
        processForObject(sourceObjectApi, affectedChildIds, mode, false);
    }

    /**
     * Full entry point. isDelete = true is used by the before-delete flow path:
     * the doomed records still exist in the DB, so processGroup excludes them
     * from the aggregation query and recomputes over the survivors (a parent
     * whose last child is being removed yields an empty set → zeroed out).
     */
    public static void processForObject(String sourceObjectApi, Set<Id> affectedChildIds, String mode, Boolean isDelete) {
        if (String.isBlank(sourceObjectApi) || affectedChildIds == null || affectedChildIds.isEmpty()) return;

        List<Rollup_Rule__c> rules = loadRules(sourceObjectApi, mode);
        if (rules.isEmpty()) return;

        // Group rules by lookup field — 1 SOQL + 1 DML per group
        Map<String, List<Rollup_Rule__c>> byLookup = new Map<String, List<Rollup_Rule__c>>();
        for (Rollup_Rule__c rule : rules) {
            if (String.isBlank(rule.Lookup_Field__c)) continue;
            if (!byLookup.containsKey(rule.Lookup_Field__c)) {
                byLookup.put(rule.Lookup_Field__c, new List<Rollup_Rule__c>());
            }
            byLookup.get(rule.Lookup_Field__c).add(rule);
        }

        for (String lookupField : byLookup.keySet()) {
            processGroup(sourceObjectApi, lookupField, byLookup.get(lookupField), affectedChildIds, isDelete);
        }
    }

    /**
     * Load all active rules for a source object, optionally filtered by mode.
     */
    public static List<Rollup_Rule__c> loadRules(String sourceObjectApi, String mode) {
        if (String.isBlank(mode)) {
            return [
                SELECT Id, Active__c, Operation__c, Lookup_Field__c, Source_Field__c,
                       Target_Field__c, Parent_Object__c, Filter_Criteria__c,
                       Concat_Delimiter__c, Mode__c,
                       Rollup_Config__r.Applicable_Object__c, Rollup_Config__r.Active__c
                FROM Rollup_Rule__c
                WHERE Active__c = true
                  AND Rollup_Config__r.Active__c = true
                  AND Rollup_Config__r.Applicable_Object__c = :sourceObjectApi
                ORDER BY Sort_Order__c ASC NULLS LAST
            ];
        }
        return [
            SELECT Id, Active__c, Operation__c, Lookup_Field__c, Source_Field__c,
                   Target_Field__c, Parent_Object__c, Filter_Criteria__c,
                   Concat_Delimiter__c, Mode__c,
                   Rollup_Config__r.Applicable_Object__c, Rollup_Config__r.Active__c
            FROM Rollup_Rule__c
            WHERE Active__c = true
              AND Rollup_Config__r.Active__c = true
              AND Rollup_Config__r.Applicable_Object__c = :sourceObjectApi
              AND Mode__c = :mode
            ORDER BY Sort_Order__c ASC NULLS LAST
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Group processor
    // ─────────────────────────────────────────────────────────────────────────

    private static void processGroup(
            String srcObj, String lookupField,
            List<Rollup_Rule__c> rules, Set<Id> affectedChildIds, Boolean isDelete) {

        // ── Step 1: Resolve parent IDs from the affected child IDs ──
        Set<Id> parentIds = resolveParentIds(srcObj, lookupField, affectedChildIds);
        if (parentIds.isEmpty()) {
            // Children may have been deleted — zero out the parents
            Set<Id> deletedParents = resolveParentIdsAllRows(srcObj, lookupField, affectedChildIds);
            if (!deletedParents.isEmpty()) zeroOutParents(rules, deletedParents);
            return;
        }

        // ── Step 2: Collect all fields needed across every rule ──
        Set<String> fieldsNeeded = new Set<String>{ 'id', lookupField.toLowerCase() };
        for (Rollup_Rule__c rule : rules) {
            if (String.isNotBlank(rule.Source_Field__c) && rule.Operation__c != 'Count') {
                fieldsNeeded.add(rule.Source_Field__c.toLowerCase());
            }
            // Add filter fields — keep full dot-notation for relationship traversal
            fieldsNeeded.addAll(RollupFilterBuilder.getRequiredFields(rule.Filter_Criteria__c));
        }

        // ── Step 3: ONE SOQL — fetch ALL children of the resolved parents ──
        String fieldList = String.join(new List<String>(fieldsNeeded), ', ');
        String soql = 'SELECT ' + fieldList
                    + ' FROM ' + srcObj
                    + ' WHERE ' + lookupField + ' IN :parentIds';

        if (isDelete == true) {
            // Before-delete: the doomed records are still live, so drop them from
            // the aggregation. Survivors recompute correctly; a parent whose last
            // child is going away yields an empty set → allChildren.isEmpty()
            // zeroes it out below.
            soql += ' AND Id NOT IN :affectedChildIds';
        }

        List<SObject> allChildren;
        try {
            allChildren = Database.query(soql);
        } catch (Exception e) {
            return; // field no longer exists or access denied — skip group silently
        }

        if (allChildren.isEmpty()) {
            zeroOutParents(rules, parentIds);
            return;
        }

        // ── Step 4: Per rule — filter in-memory, then aggregate ──
        Map<Id, Map<String, Object>> parentResults = new Map<Id, Map<String, Object>>();
        for (Id pid : parentIds) {
            parentResults.put(pid, new Map<String, Object>());
        }

        for (Rollup_Rule__c rule : rules) {
            if (String.isBlank(rule.Target_Field__c) || String.isBlank(rule.Parent_Object__c)) continue;

            String op        = rule.Operation__c;
            String srcField  = rule.Source_Field__c;
            String tgtField  = rule.Target_Field__c;
            String delimiter = String.isNotBlank(rule.Concat_Delimiter__c) ? rule.Concat_Delimiter__c : ', ';

            // Filter records in-memory for this rule
            List<SObject> filtered = new List<SObject>();
            for (SObject child : allChildren) {
                if (RollupFilterBuilder.matches(child, rule.Filter_Criteria__c)) {
                    filtered.add(child);
                }
            }

            // Aggregate the filtered set grouped by parent
            Map<Id, Object> ruleResult = aggregate(filtered, lookupField, srcField, op, delimiter);

            // Store result — null means no matching children (e.g. all filtered out)
            for (Id pid : parentIds) {
                Object val = ruleResult.containsKey(pid) ? ruleResult.get(pid) : null;
                parentResults.get(pid).put(tgtField, val);
            }
        }

        // ── Step 5: ONE DML — update all parents with all target fields ──
        writeResults(rules[0].Parent_Object__c, parentResults);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  In-memory aggregation
    // ─────────────────────────────────────────────────────────────────────────

    private static Map<Id, Object> aggregate(
            List<SObject> records, String lookupField,
            String srcField, String op, String delimiter) {

        Map<Id, Object> result = new Map<Id, Object>();
        if (records.isEmpty()) return result;

        if (op == 'Count') {
            Map<Id, Integer> counts = new Map<Id, Integer>();
            for (SObject rec : records) {
                Id pid = (Id) rec.get(lookupField);
                if (pid == null) continue;
                counts.put(pid, (counts.containsKey(pid) ? counts.get(pid) : 0) + 1);
            }
            for (Id pid : counts.keySet()) result.put(pid, counts.get(pid));
            return result;
        }

        if (op == 'Concat') {
            Map<Id, List<String>> buckets = new Map<Id, List<String>>();
            for (SObject rec : records) {
                Id pid = (Id) rec.get(lookupField);
                if (pid == null) continue;
                Object val = rec.get(srcField);
                if (val == null) continue;
                if (!buckets.containsKey(pid)) buckets.put(pid, new List<String>());
                buckets.get(pid).add(String.valueOf(val));
            }
            for (Id pid : buckets.keySet()) result.put(pid, String.join(buckets.get(pid), delimiter));
            return result;
        }

        // SUM / MIN / MAX / AVG
        Map<Id, Decimal> totals = new Map<Id, Decimal>();
        Map<Id, Integer> counts = new Map<Id, Integer>();
        Map<Id, Decimal> mins   = new Map<Id, Decimal>();
        Map<Id, Decimal> maxs   = new Map<Id, Decimal>();

        for (SObject rec : records) {
            Id pid = (Id) rec.get(lookupField);
            if (pid == null) continue;
            Object rawVal = rec.get(srcField);
            if (rawVal == null) continue;
            Decimal val;
            try { val = Decimal.valueOf(String.valueOf(rawVal)); } catch (Exception e) { continue; }

            totals.put(pid, (totals.containsKey(pid) ? totals.get(pid) : 0) + val);
            counts.put(pid, (counts.containsKey(pid) ? counts.get(pid) : 0) + 1);
            if (!mins.containsKey(pid) || val < mins.get(pid)) mins.put(pid, val);
            if (!maxs.containsKey(pid) || val > maxs.get(pid)) maxs.put(pid, val);
        }

        for (Id pid : totals.keySet()) {
            if      (op == 'Sum') result.put(pid, totals.get(pid));
            else if (op == 'Min') result.put(pid, mins.get(pid));
            else if (op == 'Max') result.put(pid, maxs.get(pid));
            else if (op == 'Avg') {
                Integer cnt = counts.get(pid);
                result.put(pid, (cnt != null && cnt > 0) ? totals.get(pid) / cnt : null);
            }
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Write all target fields to parent records in one DML
    // ─────────────────────────────────────────────────────────────────────────

    private static void writeResults(String parentObj, Map<Id, Map<String, Object>> parentResults) {
        Schema.SObjectType parentType = Schema.getGlobalDescribe().get(parentObj);
        if (parentType == null) return;

        Map<String, Schema.SObjectField> fieldMap = parentType.getDescribe().fields.getMap();
        List<SObject> toUpdate = new List<SObject>();

        for (Id pid : parentResults.keySet()) {
            SObject rec = parentType.newSObject(pid);
            for (String tgtField : parentResults.get(pid).keySet()) {
                if (!fieldMap.containsKey(tgtField.toLowerCase())) continue;
                if (!fieldMap.get(tgtField.toLowerCase()).getDescribe().isUpdateable()) continue;
                rec.put(tgtField, parentResults.get(pid).get(tgtField));
            }
            toUpdate.add(rec);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false); // partial success
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Zero out parents when all children are gone
    // ─────────────────────────────────────────────────────────────────────────

    private static void zeroOutParents(List<Rollup_Rule__c> rules, Set<Id> parentIds) {
        if (rules.isEmpty() || parentIds.isEmpty()) return;
        String parentObj = rules[0].Parent_Object__c;
        Schema.SObjectType parentType = Schema.getGlobalDescribe().get(parentObj);
        if (parentType == null) return;
        Map<String, Schema.SObjectField> fieldMap = parentType.getDescribe().fields.getMap();

        List<SObject> toUpdate = new List<SObject>();
        for (Id pid : parentIds) {
            SObject rec = parentType.newSObject(pid);
            for (Rollup_Rule__c rule : rules) {
                if (String.isBlank(rule.Target_Field__c)) continue;
                if (!fieldMap.containsKey(rule.Target_Field__c.toLowerCase())) continue;
                if (!fieldMap.get(rule.Target_Field__c.toLowerCase()).getDescribe().isUpdateable()) continue;
                rec.put(rule.Target_Field__c, rule.Operation__c == 'Count' ? 0 : null);
            }
            toUpdate.add(rec);
        }
        if (!toUpdate.isEmpty()) Database.update(toUpdate, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Resolve parent IDs from child IDs (live records)
    // ─────────────────────────────────────────────────────────────────────────

    public static Set<Id> resolveParentIds(String srcObj, String lookupFld, Set<Id> childIds) {
        Set<Id> parents = new Set<Id>();
        if (String.isBlank(srcObj) || String.isBlank(lookupFld) || childIds == null) return parents;
        String soql = 'SELECT ' + lookupFld + ' FROM ' + srcObj
                    + ' WHERE Id IN :childIds AND ' + lookupFld + ' != null';
        for (SObject rec : Database.query(soql)) {
            Id pid = (Id) rec.get(lookupFld);
            if (pid != null) parents.add(pid);
        }
        return parents;
    }

    // Resolve parent IDs including deleted records (for before-delete Flow)
    public static Set<Id> resolveParentIdsAllRows(String srcObj, String lookupFld, Set<Id> childIds) {
        Set<Id> parents = new Set<Id>();
        if (String.isBlank(srcObj) || String.isBlank(lookupFld) || childIds == null) return parents;
        String soql = 'SELECT ' + lookupFld + ' FROM ' + srcObj
                    + ' WHERE Id IN :childIds AND ' + lookupFld + ' != null ALL ROWS';
        for (SObject rec : Database.query(soql)) {
            Id pid = (Id) rec.get(lookupFld);
            if (pid != null) parents.add(pid);
        }
        return parents;
    }
}