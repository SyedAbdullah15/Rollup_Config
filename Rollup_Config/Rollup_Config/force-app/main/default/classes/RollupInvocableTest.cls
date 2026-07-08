/**
 * RollupInvocableTest
 * Tests the Flow invocable entry point.
 */
@isTest
private class RollupInvocableTest {

    @isTest
    static void testRecalculateRealtime() {
        RollupTestDataFactory.createBasicRule('Realtime');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(250);

        RollupInvocable.Request req = new RollupInvocable.Request();
        req.affectedRecordId = oli.Id;

        Test.startTest();
        RollupInvocable.recalculate(new List<RollupInvocable.Request>{ req });
        Test.stopTest();

        Opportunity opp = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(250, opp.Total_Amount__c);
    }

    @isTest
    static void testRecalculateQueueable() {
        RollupTestDataFactory.createBasicRule('Queueable');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(300);

        RollupInvocable.Request req = new RollupInvocable.Request();
        req.affectedRecordId = oli.Id;

        Test.startTest();
        RollupInvocable.recalculate(new List<RollupInvocable.Request>{ req });
        Test.stopTest();

        // Queueable runs in Test.stopTest() — verify result
        Opportunity opp = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(300, opp.Total_Amount__c);
    }

    @isTest
    static void testRecalculateBulk() {
        RollupTestDataFactory.createBasicRule('Realtime');

        // Create two separate opportunities with line items
        OpportunityLineItem oli1 = RollupTestDataFactory.createOpportunityWithLineItem(100);
        OpportunityLineItem oli2 = RollupTestDataFactory.createOpportunityWithLineItem(200);

        List<RollupInvocable.Request> requests = new List<RollupInvocable.Request>();
        RollupInvocable.Request r1 = new RollupInvocable.Request();
        r1.affectedRecordId = oli1.Id;
        RollupInvocable.Request r2 = new RollupInvocable.Request();
        r2.affectedRecordId = oli2.Id;
        requests.add(r1);
        requests.add(r2);

        Test.startTest();
        RollupInvocable.recalculate(requests);
        Test.stopTest();

        Opportunity opp1 = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli1.OpportunityId];
        Opportunity opp2 = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli2.OpportunityId];
        System.assertEquals(100, opp1.Total_Amount__c);
        System.assertEquals(200, opp2.Total_Amount__c);
    }

    @isTest
    static void testRecalculateNullRequest() {
        Test.startTest();
        RollupInvocable.recalculate(null);
        Test.stopTest();
        System.assert(true, 'No exception for null request list');
    }

    @isTest
    static void testRecalculateEmptyRequest() {
        Test.startTest();
        RollupInvocable.recalculate(new List<RollupInvocable.Request>());
        Test.stopTest();
        System.assert(true, 'No exception for empty request list');
    }

    @isTest
    static void testRecalculateNullRecordId() {
        RollupInvocable.Request req = new RollupInvocable.Request();
        req.affectedRecordId = null;
        Test.startTest();
        RollupInvocable.recalculate(new List<RollupInvocable.Request>{ req });
        Test.stopTest();
        System.assert(true, 'No exception for null record ID');
    }

    @isTest
    static void testObjectDerivedFromRecordId() {
        RollupTestDataFactory.createBasicRule('Realtime');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(750);

        // Verify engine derives object from ID without sourceObject input
        RollupInvocable.Request req = new RollupInvocable.Request();
        req.affectedRecordId = oli.Id;

        Test.startTest();
        RollupInvocable.recalculate(new List<RollupInvocable.Request>{ req });
        Test.stopTest();

        Opportunity opp = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(750, opp.Total_Amount__c, 'Object should be derived from record ID');
    }

    @isTest
    static void testScheduledRulesSkipped() {
        // Scheduled rules should not be processed by Invocable
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
            Mode__c          = 'Scheduled',
            Active__c        = true
        );

        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(500);
        RollupInvocable.Request req = new RollupInvocable.Request();
        req.affectedRecordId = oli.Id;

        Test.startTest();
        RollupInvocable.recalculate(new List<RollupInvocable.Request>{ req });
        Test.stopTest();

        Opportunity opp = [SELECT Total_Amount__c FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(null, opp.Total_Amount__c, 'Scheduled rules should not run via Invocable');
    }
}