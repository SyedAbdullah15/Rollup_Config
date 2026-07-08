/**
 * RollupBatchTest
 * Tests the historical recalculation batch job.
 * One executeBatch per test method — platform restriction.
 */
@isTest
private class RollupBatchTest {

    @isTest
    static void testBatchProcessesSingleRecord() {
        RollupTestDataFactory.createBasicRule('Scheduled');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);

        Test.startTest();
        Database.executeBatch(
            new RollupBatch('OpportunityLineItem', 'OpportunityId'), 200
        );
        Test.stopTest();

        Opportunity opp = [SELECT Amount FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(100, opp.Amount);
    }

    @isTest
    static void testBatchNoRecords() {
        RollupTestDataFactory.createBasicRule('Scheduled');

        Test.startTest();
        Database.executeBatch(
            new RollupBatch('OpportunityLineItem', 'OpportunityId'), 200
        );
        Test.stopTest();

        System.assert(true, 'No exception when no records to process');
    }

    @isTest
    static void testBatchLargerAmount() {
        RollupTestDataFactory.createBasicRule('Scheduled');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(999);

        Test.startTest();
        Database.executeBatch(
            new RollupBatch('OpportunityLineItem', 'OpportunityId'), 200
        );
        Test.stopTest();

        Opportunity opp = [SELECT Amount FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(999, opp.Amount);
    }

    @isTest
    static void testRecalculateAllApexMethod() {
        Rollup_Rule__c rule = RollupTestDataFactory.createBasicRule('Scheduled');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(500);
        Id configId = [SELECT Rollup_Config__c FROM Rollup_Rule__c WHERE Id = :rule.Id].Rollup_Config__c;

        Test.startTest();
        RollupConfigController.recalculateAll(configId);
        Test.stopTest();

        Opportunity opp = [SELECT Amount FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(500, opp.Amount);
    }

    @isTest
    static void testRecalculateAllNullConfigId() {
        try {
            RollupConfigController.recalculateAll(null);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Should throw for null config ID');
        }
    }

    @isTest
    static void testRecalculateAllInactiveConfig() {
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem',
            Active__c            = false
        );
        insert cfg;
        try {
            RollupConfigController.recalculateAll(cfg.Id);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true, 'Throws for inactive config');
        }
    }

    @isTest
    static void testRecalculateAllNoRules() {
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem',
            Active__c            = true
        );
        insert cfg;
        try {
            RollupConfigController.recalculateAll(cfg.Id);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true, 'Throws when no active rules');
        }
    }
}