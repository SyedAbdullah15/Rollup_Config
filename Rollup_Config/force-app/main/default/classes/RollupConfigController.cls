/**
 * RollupConfigController
 * Backs the rollupConfigurator LWC. One Rollup_Config__c per source object
 * (Applicable_Object__c); many Rollup_Rule__c children. Re-selecting an object
 * loads its existing config + rules so adding "another lookup field" is just
 * another rule row — never a new top-level record.
 */
public with sharing class RollupConfigController {

    // ── Wrappers ──────────────────────────────────────────────────────────────
    public class Option implements Comparable {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public Option(String l, String v) { label = l; value = v; }
        public Integer compareTo(Object o) { return label.compareTo(((Option) o).label); }
    }
    public class FieldInfo implements Comparable {
        @AuraEnabled public String  label;
        @AuraEnabled public String  apiName;
        @AuraEnabled public String  type;          // DOUBLE, CURRENCY, DATE, STRING, ...
        @AuraEnabled public Boolean isReference;
        @AuraEnabled public String  referenceTo;   // parent object for lookups
        public Integer compareTo(Object o) { return label.compareTo(((FieldInfo) o).label); }
    }
    public class RuleDTO {
        @AuraEnabled public String  lookupField;
        @AuraEnabled public String  parentObject;
        @AuraEnabled public String  operation;
        @AuraEnabled public String  sourceField;
        @AuraEnabled public String  targetField;
        @AuraEnabled public String  filterCriteria;
        @AuraEnabled public String  concatDelimiter;
        @AuraEnabled public String  mode;
        @AuraEnabled public Boolean active;
    }
    public class ConfigDTO {
        @AuraEnabled public Id      configId;
        @AuraEnabled public String  applicableObject;
        @AuraEnabled public Boolean active = true;
        @AuraEnabled public List<RuleDTO> rules = new List<RuleDTO>();
    }

    // ── Object picker ─────────────────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<Option> getObjectOptions() {
        List<Option> out = new List<Option>();
        for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult d = t.getDescribe();
            if (!d.isAccessible() || !d.isQueryable() || d.isCustomSetting()) continue;
            String nm = d.getName();
            if (nm.endsWith('__Share') || nm.endsWith('__History') || nm.endsWith('__Feed')
                || nm.endsWith('ChangeEvent') || nm.endsWith('__e') || nm.endsWith('__mdt')) continue;
            out.add(new Option(d.getLabel() + ' (' + nm + ')', nm));
        }
        out.sort();
        return out;
    }

    // Lookup (reference) fields on the source object → drive parent + target list
    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> getLookupFields(String objectApiName) {
        List<FieldInfo> out = new List<FieldInfo>();
        Schema.SObjectType t = safeType(objectApiName);
        if (t == null) return out;
        for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (!d.isAccessible()) continue;
            if (d.getType() == Schema.DisplayType.REFERENCE && !d.getReferenceTo().isEmpty()) {
                FieldInfo fi = new FieldInfo();
                fi.label = d.getLabel(); fi.apiName = d.getName();
                fi.type = 'REFERENCE'; fi.isReference = true;
                fi.referenceTo = String.valueOf(d.getReferenceTo()[0]);
                out.add(fi);
            }
        }
        out.sort();
        return out;
    }

    // All accessible fields on an object (used for Source + Target pickers; the
    // LWC filters them by type per operation).
    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> getFields(String objectApiName) {
        List<FieldInfo> out = new List<FieldInfo>();
        Schema.SObjectType t = safeType(objectApiName);
        if (t == null) return out;
        for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (!d.isAccessible()) continue;
            FieldInfo fi = new FieldInfo();
            fi.label = d.getLabel(); fi.apiName = d.getName();
            fi.type = String.valueOf(d.getType());
            fi.isReference = (d.getType() == Schema.DisplayType.REFERENCE);
            out.add(fi);
        }
        out.sort();
        return out;
    }

    // Load the single config (if any) for an object + its rules.
    @AuraEnabled(cacheable=false)
    public static ConfigDTO getConfig(String objectApiName) {
        ConfigDTO dto = new ConfigDTO();
        if (String.isBlank(objectApiName)) return dto;
        List<Rollup_Config__c> cfgs = [
            SELECT Id, Active__c,
                   (SELECT Lookup_Field__c, Parent_Object__c, Operation__c, Source_Field__c,
                           Target_Field__c, Filter_Criteria__c, Concat_Delimiter__c, Mode__c, Active__c
                    FROM Rollup_Rules__r ORDER BY Sort_Order__c ASC NULLS LAST)
            FROM Rollup_Config__c
            WHERE Applicable_Object__c = :objectApiName
            LIMIT 1
        ];
        if (cfgs.isEmpty()) return dto;
        Rollup_Config__c cfg = cfgs[0];
        dto.configId = cfg.Id;
        dto.applicableObject = objectApiName;
        dto.active = cfg.Active__c;
        for (Rollup_Rule__c r : cfg.Rollup_Rules__r) {
            dto.rules.add(toRuleDto(r));
        }
        return dto;
    }

    // Record-page mode: load a specific Rollup_Config__c by its Id.
    @AuraEnabled(cacheable=false)
    public static ConfigDTO getConfigById(Id recordId) {
        ConfigDTO dto = new ConfigDTO();
        if (recordId == null) return dto;
        List<Rollup_Config__c> cfgs = [
            SELECT Id, Applicable_Object__c, Active__c,
                   (SELECT Lookup_Field__c, Parent_Object__c, Operation__c, Source_Field__c,
                           Target_Field__c, Filter_Criteria__c, Concat_Delimiter__c, Mode__c, Active__c
                    FROM Rollup_Rules__r ORDER BY Sort_Order__c ASC NULLS LAST)
            FROM Rollup_Config__c
            WHERE Id = :recordId
            LIMIT 1
        ];
        if (cfgs.isEmpty()) return dto;
        Rollup_Config__c cfg = cfgs[0];
        dto.configId = cfg.Id;
        dto.applicableObject = cfg.Applicable_Object__c;
        dto.active = cfg.Active__c;
        for (Rollup_Rule__c r : cfg.Rollup_Rules__r) {
            dto.rules.add(toRuleDto(r));
        }
        return dto;
    }

    private static RuleDTO toRuleDto(Rollup_Rule__c r) {
        RuleDTO rd = new RuleDTO();
        rd.lookupField     = r.Lookup_Field__c;
        rd.parentObject    = r.Parent_Object__c;
        rd.operation       = r.Operation__c;
        rd.sourceField     = r.Source_Field__c;
        rd.targetField     = r.Target_Field__c;
        rd.filterCriteria  = r.Filter_Criteria__c;
        rd.concatDelimiter = r.Concat_Delimiter__c;
        rd.mode            = r.Mode__c;
        rd.active          = r.Active__c;
        return rd;
    }

    // Upsert the single config for the object, then replace its rules wholesale
    // (delete-then-insert under a Savepoint) — so re-saving never duplicates.
    @AuraEnabled
    public static void saveConfig(String objectApiName, Boolean active, String rulesJson, Id configId) {
        if (String.isBlank(objectApiName)) throw new AuraHandledException('Object is required.');
        List<RuleDTO> rules = (List<RuleDTO>) JSON.deserialize(
            String.isBlank(rulesJson) ? '[]' : rulesJson, List<RuleDTO>.class);

        Savepoint sp = Database.setSavepoint();
        try {
            Rollup_Config__c cfg;
            if (configId != null) {
                // Record-page mode — update exactly this record.
                cfg = [SELECT Id, Applicable_Object__c FROM Rollup_Config__c WHERE Id = :configId LIMIT 1];
            } else {
                // Standalone mode — one config per object. Reuse if it already exists.
                List<Rollup_Config__c> existing = [
                    SELECT Id FROM Rollup_Config__c WHERE Applicable_Object__c = :objectApiName LIMIT 1];
                cfg = existing.isEmpty()
                    ? new Rollup_Config__c(Applicable_Object__c = objectApiName)
                    : existing[0];
            }
            // Guard: never let two configs share the same object.
            List<Rollup_Config__c> dupes = [
                SELECT Id FROM Rollup_Config__c
                WHERE Applicable_Object__c = :objectApiName AND Id != :cfg.Id];
            if (!dupes.isEmpty()) {
                throw new AuraHandledException('A rollup configuration already exists for ' + objectApiName + '.');
            }
            cfg.Active__c = active;
            upsert cfg;

            delete [SELECT Id FROM Rollup_Rule__c WHERE Rollup_Config__c = :cfg.Id];

            List<Rollup_Rule__c> toInsert = new List<Rollup_Rule__c>();
            Integer i = 0;
            for (RuleDTO rd : rules) {
                toInsert.add(new Rollup_Rule__c(
                    Rollup_Config__c   = cfg.Id,
                    Lookup_Field__c    = rd.lookupField,
                    Parent_Object__c   = rd.parentObject,
                    Operation__c       = rd.operation,
                    Source_Field__c    = rd.sourceField,
                    Target_Field__c    = rd.targetField,
                    Filter_Criteria__c = rd.filterCriteria,
                    Concat_Delimiter__c= rd.concatDelimiter,
                    Mode__c            = rd.mode,
                    Active__c          = rd.active == null ? true : rd.active,
                    Sort_Order__c      = i++
                ));
            }
            if (!toInsert.isEmpty()) insert toInsert;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Save failed: ' + e.getMessage());
        }
    }

    private static Schema.SObjectType safeType(String apiName) {
        if (String.isBlank(apiName)) return null;
        return Schema.getGlobalDescribe().get(apiName);
    }

    // ── Filter builder field metadata (type-aware values + relationship drill) ──
    public class CondField implements Comparable {
        @AuraEnabled public String       label;
        @AuraEnabled public String       apiName;
        @AuraEnabled public String       type;
        @AuraEnabled public Boolean      isReference;
        @AuraEnabled public String       referenceTo;
        @AuraEnabled public String       relationshipName;
        @AuraEnabled public List<String> picklistValues;
        public Integer compareTo(Object o) { return label.compareTo(((CondField) o).label); }
    }
    @AuraEnabled(cacheable=true)
    public static List<CondField> getConditionFields(String objectApiName) {
        List<CondField> out = new List<CondField>();
        Schema.SObjectType t = safeType(objectApiName);
        if (t == null) return out;
        for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (!d.isAccessible()) continue;
            CondField cf = new CondField();
            cf.label = d.getLabel(); cf.apiName = d.getName();
            cf.type = String.valueOf(d.getType());
            cf.isReference = (d.getType() == Schema.DisplayType.REFERENCE) && !d.getReferenceTo().isEmpty();
            if (cf.isReference) {
                cf.referenceTo      = String.valueOf(d.getReferenceTo()[0]);
                cf.relationshipName = d.getRelationshipName();
            }
            if (d.getType() == Schema.DisplayType.PICKLIST || d.getType() == Schema.DisplayType.MULTIPICKLIST) {
                cf.picklistValues = new List<String>();
                for (Schema.PicklistEntry pe : d.getPicklistValues()) {
                    if (pe.isActive()) cf.picklistValues.add(pe.getValue());
                }
            }
            out.add(cf);
        }
        out.sort();
        return out;
    }

    @AuraEnabled
    public static void recalculateAll(Id configId) {
        if (configId == null) throw new AuraHandledException('Config ID is required.');

        List<Rollup_Config__c> cfgs = [
            SELECT Id, Applicable_Object__c,
                   (SELECT Lookup_Field__c FROM Rollup_Rules__r
                    WHERE Active__c = true ORDER BY Sort_Order__c ASC NULLS LAST LIMIT 1)
            FROM Rollup_Config__c
            WHERE Id = :configId AND Active__c = true
            LIMIT 1
        ];

        if (cfgs.isEmpty()) throw new AuraHandledException('No active rollup configuration found.');

        Rollup_Config__c cfg = cfgs[0];
        if (String.isBlank(cfg.Applicable_Object__c)) throw new AuraHandledException('Configuration has no applicable object set.');
        if (cfg.Rollup_Rules__r.isEmpty()) throw new AuraHandledException('No active rules found on this configuration.');

        Database.executeBatch(
            new RollupBatch(cfg.Applicable_Object__c, cfg.Rollup_Rules__r[0].Lookup_Field__c),
            200
        );
    }
}