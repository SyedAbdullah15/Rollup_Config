@IsTest
private class RollupConfigControllerTest {

    @TestSetup
    static void setup() {
        // Create a parent and child object for testing
        // Note: In real orgs, use standard objects like Account/Contact if possible,
        // or ensure these custom objects exist in your environment.
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem'
        );
        insert cfg;

        Rollup_Rule__c rule = new Rollup_Rule__c(
            Rollup_Config__c = cfg.Id,
            Lookup_Field__c = 'ParentId',
            Operation__c = 'SUM',
            Active__c = true
        );
        insert rule;
    }

    @IsTest
    static void testGetOptionsAndFields() {
        Test.startTest();
        List<RollupConfigController.Option> options = RollupConfigController.getObjectOptions();
        List<RollupConfigController.FieldInfo> fields = RollupConfigController.getFields('Account');
        List<RollupConfigController.FieldInfo> lookups = RollupConfigController.getLookupFields('Account');
        List<RollupConfigController.CondField> condFields = RollupConfigController.getConditionFields('Account');
        Test.stopTest();

        System.assert(!options.isEmpty(), 'Should return objects');
        System.assert(!fields.isEmpty(), 'Should return fields');
    }

    @IsTest
    static void testGetConfig() {
        Rollup_Config__c existing = [SELECT Id FROM Rollup_Config__c LIMIT 1];
        
        Test.startTest();
        RollupConfigController.ConfigDTO dto = RollupConfigController.getConfig('Account');
        RollupConfigController.ConfigDTO dtoById = RollupConfigController.getConfigById(existing.Id);
        Test.stopTest();
    }

    @IsTest
    static void testSaveConfig() {
        RollupConfigController.RuleDTO newRule = new RollupConfigController.RuleDTO();
        newRule.lookupField = 'ParentId';
        newRule.operation = 'COUNT';
        newRule.active = true;

        String rulesJson = JSON.serialize(new List<RollupConfigController.RuleDTO>{newRule});

        Test.startTest();
        RollupConfigController.saveConfig('Account', true, rulesJson, null);
        Test.stopTest();

        List<Rollup_Rule__c> rules = [SELECT Id FROM Rollup_Rule__c WHERE Rollup_Config__c IN (SELECT Id FROM Rollup_Config__c WHERE Applicable_Object__c = 'Account')];
        System.assertEquals(1, rules.size(), 'Should have deleted old rules and inserted the new one');
    }
/*
    @IsTest
    static void testRecalculateAll() {
        Rollup_Config__c cfg = [SELECT Id FROM Rollup_Config__c LIMIT 1];
        
        Test.startTest();
        // This will queue a batch job
        RollupConfigController.recalculateAll(cfg.Id);
        Test.stopTest();

        List<AsyncApexJob> jobs = [SELECT Id FROM AsyncApexJob WHERE JobType = 'BatchApex'];
        System.assertEquals(1, jobs.size(), 'Batch job should be queued');
    } */
}