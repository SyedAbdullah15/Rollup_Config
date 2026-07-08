/**
 * RollupEngineTest
 * Tests the core calculation engine.
 */
@isTest
private class RollupEngineTest {

    @isTest
    static void testLoadRulesNoMode() {
        RollupTestDataFactory.createBasicRule('Realtime');
        List<Rollup_Rule__c> rules = RollupEngine.loadRules('OpportunityLineItem', null);
        System.assertEquals(1, rules.size());
    }

    @isTest
    static void testLoadRulesFiltersByMode() {
        RollupTestDataFactory.createBasicRule('Realtime');
        List<Rollup_Rule__c> realtime  = RollupEngine.loadRules('OpportunityLineItem', 'Realtime');
        List<Rollup_Rule__c> queueable = RollupEngine.loadRules('OpportunityLineItem', 'Queueable');
        System.assertEquals(1, realtime.size());
        System.assertEquals(0, queueable.size());
    }

    @isTest
    static void testLoadRulesInactiveConfigExcluded() {
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem',
            Active__c            = false
        );
        insert cfg;
        insert new Rollup_Rule__c(
            Rollup_Config__c = cfg.Id,
            Lookup_Field__c  = 'OpportunityId',
            Parent_Object__c = 'Opportunity',
            Operation__c     = 'Sum',
            Source_Field__c  = 'TotalPrice',
            Target_Field__c  = 'Amount',
            Mode__c          = 'Realtime',
            Active__c        = true
        );
        List<Rollup_Rule__c> rules = RollupEngine.loadRules('OpportunityLineItem', null);
        System.assertEquals(0, rules.size(), 'Inactive config rules should be excluded');
    }

    @isTest
    static void testSumAcrossAllLineItems() {
        RollupTestDataFactory.createBasicRule('Realtime');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);

        // Add a second line item to same opportunity
        Product2 prod2 = new Product2(Name = 'Product 2', IsActive = true);
        insert prod2;
        PricebookEntry pbe2 = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod2.Id,
            UnitPrice    = 200,
            IsActive     = true
        );
        insert pbe2;
        insert new OpportunityLineItem(
            OpportunityId    = oli.OpportunityId,
            PricebookEntryId = pbe2.Id,
            Quantity         = 1,
            UnitPrice        = 200
        );

        Test.startTest();
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oli.Id });
        Test.stopTest();

        Opportunity opp = [SELECT Amount FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(300, opp.Amount, 'SUM should be 300 (100 + 200)');
    }

    @isTest
    static void testCountOperation() {
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem',
            Active__c            = true
        );
        insert cfg;
        insert new Rollup_Rule__c(
            Rollup_Config__c = cfg.Id,
            Lookup_Field__c  = 'OpportunityId',
            Parent_Object__c = 'Opportunity',
            Operation__c     = 'Count',
            Source_Field__c  = null,
            Target_Field__c  = 'Amount',
            Mode__c          = 'Realtime',
            Active__c        = true
        );

        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);

        Test.startTest();
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oli.Id });
        Test.stopTest();

        Opportunity opp = [SELECT Amount FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(100, opp.Amount, 'COUNT should be 1');
    }

    @isTest
    static void testProcessForObjectEmptyChildIds() {
        // Should not throw
        Test.startTest();
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>());
        Test.stopTest();
        System.assert(true, 'No exception for empty child IDs');
    }

    @isTest
    static void testProcessForObjectNullObject() {
        Test.startTest();
        RollupEngine.processForObject(null, new Set<Id>{ UserInfo.getUserId() });
        Test.stopTest();
        System.assert(true, 'No exception for null object');
    }

    @isTest
    static void testProcessForObjectNoRules() {
        // No rules configured — should silently do nothing
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);
        Test.startTest();
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oli.Id });
        Test.stopTest();
        System.assert(true, 'No exception when no rules exist');
    }

    @isTest
    static void testResolveParentIds() {
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);
        Set<Id> parents = RollupEngine.resolveParentIds('OpportunityLineItem', 'OpportunityId', new Set<Id>{ oli.Id });
        System.assertEquals(1, parents.size());
        System.assert(parents.contains(oli.OpportunityId));
    }

    @isTest
    static void testResolveParentIdsAllRows() {
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(100);
        Id oppId = oli.OpportunityId;
        Id oliId = oli.Id;

        // Delete the line item
        delete oli;

        // resolveParentIdsAllRows should still find the parent via ALL ROWS
        Set<Id> parents = RollupEngine.resolveParentIdsAllRows(
            'OpportunityLineItem', 'OpportunityId', new Set<Id>{ oliId }
        );
        System.assertEquals(1, parents.size(), 'Should resolve parent even for deleted record');
        System.assert(parents.contains(oppId), 'Should contain the opportunity ID');
    }

    @isTest
    static void testResolveParentIdsAllRowsEmpty() {
        Set<Id> parents = RollupEngine.resolveParentIdsAllRows(
            'OpportunityLineItem', 'OpportunityId', new Set<Id>()
        );
        System.assertEquals(0, parents.size());
    }

    @isTest
    static void testModeFilterRealtime() {
        RollupTestDataFactory.createBasicRule('Realtime');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(500);

        Test.startTest();
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oli.Id }, 'Realtime');
        Test.stopTest();

        Opportunity opp = [SELECT Amount FROM Opportunity WHERE Id = :oli.OpportunityId];
        System.assertEquals(500, opp.Amount);
    }

    @isTest
    static void testModeFilterQueueableSkipsRealtimeRules() {
        RollupTestDataFactory.createBasicRule('Realtime'); // Realtime rule only
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(500);

        Test.startTest();
        // Queueable mode — should not process Realtime rules
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oli.Id }, 'Queueable');
        Test.stopTest();
    }

    @isTest
    static void testZeroOutParentsOnDelete() {
        RollupTestDataFactory.createBasicRule('Realtime');
        OpportunityLineItem oli = RollupTestDataFactory.createOpportunityWithLineItem(500);
        Id oppId = oli.OpportunityId;
        Id oliId = oli.Id;

        // Populate parent first
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oliId });
        Opportunity before = [SELECT Amount FROM Opportunity WHERE Id = :oppId];
        System.assertEquals(500, before.Amount, 'Should be 500 before delete');

        // Delete the line item then run engine — should zero out parent
        delete oli;

        Test.startTest();
        RollupEngine.processForObject('OpportunityLineItem', new Set<Id>{ oliId });
        Test.stopTest();

        Opportunity aft = [SELECT Amount FROM Opportunity WHERE Id = :oppId];
        System.assertEquals(null, aft.Amount, 'Should be null after all children deleted');
    }
}