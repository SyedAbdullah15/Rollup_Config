/**
 * RollupFilterBuilderTest
 * Tests the in-memory filter evaluator.
 */
@isTest
private class RollupFilterBuilderTest {

    // ── matches() ────────────────────────────────────────────────────────────

    @isTest
    static void testNullFilterReturnsTrue() {
        Account acc = new Account(Name = 'Test');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, null));
    }

    @isTest
    static void testBlankFilterReturnsTrue() {
        Account acc = new Account(Name = 'Test');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, ''));
    }

    @isTest
    static void testNullRecordReturnsTrue() {
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '==', 'Test');
        System.assertEquals(true, RollupFilterBuilder.matches(null, filterJson));
    }

    @isTest
    static void testStringEqualsMatch() {
        insert new Account(Name = 'Acme');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '==', 'Acme');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testStringEqualsNoMatch() {
        insert new Account(Name = 'Acme');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '==', 'Other');
        System.assertEquals(false, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testStringNotEquals() {
        insert new Account(Name = 'Acme');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '!=', 'Other');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testStringContains() {
        insert new Account(Name = 'Acme Corp');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', 'contains', 'Acme');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testBooleanTrue() {
        insert new Product2(Name = 'Test', IsActive = true);
        Product2 prod = [SELECT Id, IsActive FROM Product2 LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('IsActive', 'BOOLEAN', '==', 'true');
        System.assertEquals(true, RollupFilterBuilder.matches(prod, filterJson));
    }

    @isTest
    static void testBooleanFalse() {
        insert new Product2(Name = 'Test', IsActive = false);
        Product2 prod = [SELECT Id, IsActive FROM Product2 LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('IsActive', 'BOOLEAN', '==', 'false');
        System.assertEquals(true, RollupFilterBuilder.matches(prod, filterJson));
    }

    @isTest
    static void testNumericGreaterThan() {
        insert new Account(Name = 'Test', NumberOfEmployees = 5000);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '>', '1000');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testNumericLessThan() {
        insert new Account(Name = 'Test', NumberOfEmployees = 500);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '<', '1000');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testIsBlank() {
        insert new Account(Name = 'Test', Phone = null);
        Account acc = [SELECT Id, Phone FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Phone', 'STRING', 'isblank', '');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testIsNotBlank() {
        insert new Account(Name = 'Test', Phone = '1234567890');
        Account acc = [SELECT Id, Phone FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Phone', 'STRING', 'isnotblank', '');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testInList() {
        insert new Account(Name = 'Test', Type = 'Customer');
        Account acc = [SELECT Id, Type FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Type', 'STRING', 'in', 'Customer, Partner');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testInListNoMatch() {
        insert new Account(Name = 'Test', Type = 'Other');
        Account acc = [SELECT Id, Type FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Type', 'STRING', 'in', 'Customer, Partner');
        System.assertEquals(false, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testAndLogicAllMatch() {
        insert new Account(Name = 'Acme', Type = 'Customer');
        Account acc = [SELECT Id, Name, Type FROM Account LIMIT 1];
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'      => 'AND',
            'customLogic'=> '',
            'conditions' => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Acme' },
                new Map<String,Object>{ 'field'=>'Type', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Customer' }
            }
        });
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testAndLogicOneFails() {
        insert new Account(Name = 'Acme', Type = 'Partner');
        Account acc = [SELECT Id, Name, Type FROM Account LIMIT 1];
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'      => 'AND',
            'customLogic'=> '',
            'conditions' => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Acme' },
                new Map<String,Object>{ 'field'=>'Type', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Customer' }
            }
        });
        System.assertEquals(false, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testOrLogic() {
        insert new Account(Name = 'Acme', Type = 'Partner');
        Account acc = [SELECT Id, Name, Type FROM Account LIMIT 1];
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'      => 'OR',
            'customLogic'=> '',
            'conditions' => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Other' },
                new Map<String,Object>{ 'field'=>'Type', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Partner' }
            }
        });
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testCustomLogic() {
        insert new Account(Name = 'Acme', Type = 'Partner', NumberOfEmployees = 5000);
        Account acc = [SELECT Id, Name, Type, NumberOfEmployees FROM Account LIMIT 1];
        // 1 AND (2 OR 3) — condition 1 matches, condition 3 matches → true
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'       => 'CUSTOM',
            'customLogic' => '1 AND (2 OR 3)',
            'conditions'  => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name',              'fieldType'=>'STRING',  'operator'=>'==', 'value'=>'Acme'     },
                new Map<String,Object>{ 'field'=>'Type',              'fieldType'=>'STRING',  'operator'=>'==', 'value'=>'Customer' },
                new Map<String,Object>{ 'field'=>'NumberOfEmployees', 'fieldType'=>'INTEGER', 'operator'=>'>',  'value'=>'1000'    }
            }
        });
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    // ── Date conditions ───────────────────────────────────────────────────────

    @isTest
    static void testDateEquals() {
        Date today = Date.today();
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=today);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', '==', String.valueOf(today)
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testDateNotEquals() {
        Date today = Date.today();
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=today);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', '!=', String.valueOf(today.addDays(-5))
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testDateGreaterThan() {
        Date future = Date.today().addDays(10);
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=future);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', '>', String.valueOf(Date.today())
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testDateLessThan() {
        Date past = Date.today().addDays(-10);
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=past);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', '<', String.valueOf(Date.today())
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testDateGreaterOrEqual() {
        Date today = Date.today();
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=today);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', '>=', String.valueOf(today)
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testDateLessOrEqual() {
        Date today = Date.today();
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=today);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', '<=', String.valueOf(today)
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testLastNDays() {
        Date yesterday = Date.today().addDays(-1);
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=yesterday);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', 'last_n_days', '7'
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    @isTest
    static void testNextNDays() {
        Date tomorrow = Date.today().addDays(1);
        insert new Opportunity(Name='Test', StageName='Prospecting', CloseDate=tomorrow);
        Opportunity opp = [SELECT Id, CloseDate FROM Opportunity LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson(
            'CloseDate', 'DATE', 'next_n_days', '7'
        );
        System.assertEquals(true, RollupFilterBuilder.matches(opp, filterJson));
    }

    // ── Numeric — remaining operators ─────────────────────────────────────────

    @isTest
    static void testNumericEquals() {
        insert new Account(Name='Test', NumberOfEmployees=100);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '==', '100');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testNumericNotEquals() {
        insert new Account(Name='Test', NumberOfEmployees=100);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '!=', '200');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testNumericGreaterOrEqual() {
        insert new Account(Name='Test', NumberOfEmployees=100);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '>=', '100');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testNumericLessOrEqual() {
        insert new Account(Name='Test', NumberOfEmployees=100);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '<=', '100');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testNumericBadValue() {
        insert new Account(Name='Test', NumberOfEmployees=100);
        Account acc = [SELECT Id, NumberOfEmployees FROM Account LIMIT 1];
        // Non-numeric filter value — should return false gracefully
        String filterJson = RollupTestDataFactory.buildFilterJson('NumberOfEmployees', 'INTEGER', '>', 'notanumber');
        System.assertEquals(false, RollupFilterBuilder.matches(acc, filterJson));
    }

    // ── String — remaining operators ──────────────────────────────────────────

    @isTest
    static void testStringGreaterThan() {
        insert new Account(Name='Z Corp');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '>', 'A');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testStringLessThan() {
        insert new Account(Name='Apple');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '<', 'Z');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testStringGreaterOrEqual() {
        insert new Account(Name='Acme');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '>=', 'Acme');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testStringLessOrEqual() {
        insert new Account(Name='Acme');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        String filterJson = RollupTestDataFactory.buildFilterJson('Name', 'STRING', '<=', 'Acme');
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    // ── Custom logic — NOT operator ───────────────────────────────────────────

    @isTest
    static void testCustomLogicNot() {
        insert new Account(Name='Acme', Type='Partner');
        Account acc = [SELECT Id, Name, Type FROM Account LIMIT 1];
        // NOT 2 — Type != Customer should be true
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'       => 'CUSTOM',
            'customLogic' => '1 AND NOT 2',
            'conditions'  => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Acme'     },
                new Map<String,Object>{ 'field'=>'Type', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Customer' }
            }
        });
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testCustomLogicOr() {
        insert new Account(Name='Acme', Type='Partner');
        Account acc = [SELECT Id, Name, Type FROM Account LIMIT 1];
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'       => 'CUSTOM',
            'customLogic' => '1 OR 2',
            'conditions'  => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Other'    },
                new Map<String,Object>{ 'field'=>'Type', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Partner'  }
            }
        });
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testCustomLogicOutOfRange() {
        insert new Account(Name='Acme');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        // Condition index out of range — should default false for that condition
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'       => 'CUSTOM',
            'customLogic' => '1 AND 99',
            'conditions'  => new List<Object>{
                new Map<String,Object>{ 'field'=>'Name', 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Acme' }
            }
        });
        System.assertEquals(false, RollupFilterBuilder.matches(acc, filterJson));
    }

    // ── Corrupt JSON fallback ─────────────────────────────────────────────────

    @isTest
    static void testCorruptJsonReturnsTrue() {
        insert new Account(Name='Test');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        System.assertEquals(true, RollupFilterBuilder.matches(acc, '{not:valid}'));
    }

    @isTest
    static void testNullFieldInCondition() {
        insert new Account(Name='Test');
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];
        // Condition with null field — should return true (skip)
        String filterJson = JSON.serialize(new Map<String, Object>{
            'logic'      => 'AND',
            'customLogic'=> '',
            'conditions' => new List<Object>{
                new Map<String,Object>{ 'field'=>null, 'fieldType'=>'STRING', 'operator'=>'==', 'value'=>'Test' }
            }
        });
        System.assertEquals(true, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testNullRawValueReturnsFalse() {
        insert new Account(Name='Test', Phone=null);
        Account acc = [SELECT Id, Phone FROM Account LIMIT 1];
        // Phone is null — equality check should return false
        String filterJson = RollupTestDataFactory.buildFilterJson('Phone', 'STRING', '==', '1234');
        System.assertEquals(false, RollupFilterBuilder.matches(acc, filterJson));
    }

    @isTest
    static void testGetRequiredFieldsSimple() {
        String filterJson = RollupTestDataFactory.buildFilterJson('Amount', 'CURRENCY', '>', '1000');
        Set<String> fields = RollupFilterBuilder.getRequiredFields(filterJson);
        System.assert(fields.contains('amount'), 'Should contain amount');
    }

    @isTest
    static void testGetRequiredFieldsRelationship() {
        String filterJson = RollupTestDataFactory.buildFilterJson('Product2.IsActive', 'BOOLEAN', '==', 'true');
        Set<String> fields = RollupFilterBuilder.getRequiredFields(filterJson);
        System.assert(fields.contains('product2.isactive'), 'Should contain full dot-notation path');
    }

    @isTest
    static void testGetRequiredFieldsBlank() {
        Set<String> fields = RollupFilterBuilder.getRequiredFields('');
        System.assertEquals(0, fields.size());
    }

    @isTest
    static void testGetRequiredFieldsCorruptJson() {
        Set<String> fields = RollupFilterBuilder.getRequiredFields('{not valid json}');
        System.assertEquals(0, fields.size());
    }
}