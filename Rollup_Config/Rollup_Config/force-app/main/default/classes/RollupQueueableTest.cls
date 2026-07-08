/**
 * RollupQueueableTest
 * Tests async queueable execution.
 */
@isTest
private class RollupQueueableTest {

    @isTest
    static void testQueueableExecutes() {
        RollupTestDataFactory.createBasicRule('Queueable');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(400);

        Test.startTest();
        System.enqueueJob(new RollupQueueable('OpportunityLineItem', new Set<Id>{ oli.Id }));
        Test.stopTest();

        Opportunity opp = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(400, opp.Total_Amount__c);
    }

    @isTest
    static void testQueueableEmptyIds() {
        Test.startTest();
        System.enqueueJob(new RollupQueueable('OpportunityLineItem', new Set<Id>()));
        Test.stopTest();
        System.assert(true, 'No exception for empty child IDs');
    }

    @isTest
    static void testQueueableNullObject() {
        Test.startTest();
        System.enqueueJob(new RollupQueueable(null, new Set<Id>{ UserInfo.getUserId() }));
        Test.stopTest();
        System.assert(true, 'No exception for null source object');
    }

    @isTest
    static void testQueueableMultipleRules() {
        // Two rules on same object — both should process in one job
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem',
            Active__c            = true
        );
        insert cfg;
        insert new Rollup_Rule__c(
            Rollup_Config__c = cfg.Id,
            Lookup_Field__c  = 'OpportunityId',
            Parent_Object__c = 'Opportunity',
            Operation__c     = 'Sum',
            Source_Field__c  = 'TotalPrice',
            Target_Field__c  = 'Total_Amount__c',
            Mode__c          = 'Queueable',
            Active__c        = true,
            Sort_Order__c    = 1
        );
        insert new Rollup_Rule__c(
            Rollup_Config__c = cfg.Id,
            Lookup_Field__c  = 'OpportunityId',
            Parent_Object__c = 'Opportunity',
            Operation__c     = 'Count',
            Source_Field__c  = null,
            Target_Field__c  = 'Total_Amount__c',
            Mode__c          = 'Queueable',
            Active__c        = true,
            Sort_Order__c    = 2
        );

        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);

        Test.startTest();
        System.enqueueJob(new RollupQueueable('OpportunityLineItem', new Set<Id>{ oli.Id }));
        Test.stopTest();

        System.assert(true, 'Multiple rules processed without exception');
    }
}