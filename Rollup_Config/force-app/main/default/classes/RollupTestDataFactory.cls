/**
 * RollupTestDataFactory
 * Shared test data setup for all Rollup tool test classes.
 */
@isTest
public class RollupTestDataFactory {

    /**
     * Creates a Rollup_Config__c + Rollup_Rule__c for OpportunityLineItem → Opportunity.
     * SUM of TotalPrice into Total_Amount__c.
     */
    public static Rollup_Rule__c createBasicRule(String mode) {
        Rollup_Config__c cfg = new Rollup_Config__c(
            Applicable_Object__c = 'OpportunityLineItem',
            Active__c            = true
        );
        insert cfg;

        Rollup_Rule__c rule = new Rollup_Rule__c(
            Rollup_Config__c = cfg.Id,
            Lookup_Field__c  = 'OpportunityId',
            Parent_Object__c = 'Opportunity',
            Operation__c     = 'Sum',
            Source_Field__c  = 'TotalPrice',
            Target_Field__c  = 'Total_Amount__c',
            Mode__c          = mode,
            Active__c        = true,
            Sort_Order__c    = 1
        );
        insert rule;
        return rule;
    }

    /**
     * Creates a standard Opportunity with one Product line item.
     */
    public static OpportunityLineItem createOpportunityWithLineItem(Decimal unitPrice) {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name        = 'Test Opportunity',
            AccountId   = acc.Id,
            StageName   = 'Prospecting',
            CloseDate   = Date.today().addDays(30)
        );
        insert opp;

        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = unitPrice,
            IsActive     = true
        );
        insert pbe;

        OpportunityLineItem oli = new OpportunityLineItem(
            OpportunityId  = opp.Id,
            PricebookEntryId = pbe.Id,
            Quantity       = 1,
            UnitPrice      = unitPrice
        );
        insert oli;
        return oli;
    }

    /**
     * Creates a filter JSON string for a simple condition.
     */
    public static String buildFilterJson(String field, String fieldType, String operator, String value) {
        return JSON.serialize(new Map<String, Object>{
            'logic'      => 'AND',
            'customLogic'=> '',
            'conditions' => new List<Object>{
                new Map<String, Object>{
                    'field'    => field,
                    'fieldType'=> fieldType,
                    'operator' => operator,
                    'value'    => value
                }
            }
        });
    }
}