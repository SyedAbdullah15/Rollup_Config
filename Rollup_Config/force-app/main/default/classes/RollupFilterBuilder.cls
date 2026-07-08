/**
 * RollupFilterBuilder
 * Evaluates a structured filter JSON (from Filter_Criteria__c) against an
 * in-memory SObject record. Returns true if the record matches.
 *
 * Called by RollupEngine after the single bulk SOQL — no database queries here.
 *
 * JSON shape (same as what the LWC saves):
 * {
 *   "logic": "AND" | "OR" | "CUSTOM",
 *   "customLogic": "1 AND (2 OR 3)",
 *   "conditions": [
 *     { "field": "IsActive", "fieldType": "BOOLEAN", "operator": "==", "value": "true" },
 *     { "field": "StageName", "fieldType": "STRING",  "operator": "==", "value": "Closed Won" }
 *   ]
 * }
 */
public with sharing class RollupFilterBuilder {

    // ─────────────────────────────────────────────────────────────────────────
    //  Public entry point
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns true if the SObject record passes all filter conditions.
     * If filterJson is blank or has no conditions, returns true (include all).
     */
    public static Boolean matches(SObject record, String filterJson) {
        if (String.isBlank(filterJson) || record == null) return true;

        FilterDef fd;
        try {
            fd = (FilterDef) JSON.deserialize(filterJson, FilterDef.class);
        } catch (Exception e) {
            return true; // corrupt JSON — include record rather than silently drop it
        }

        if (fd == null || fd.conditions == null || fd.conditions.isEmpty()) return true;

        String logic = String.isNotBlank(fd.logic) ? fd.logic.toUpperCase() : 'AND';

        // Evaluate each condition against the record
        List<Boolean> results = new List<Boolean>();
        for (Condition c : fd.conditions) {
            results.add(evaluateCondition(record, c));
        }

        if (logic == 'AND') {
            for (Boolean r : results) { if (!r) return false; }
            return true;
        }
        if (logic == 'OR') {
            for (Boolean r : results) { if (r) return true; }
            return false;
        }
        if (logic == 'CUSTOM' && String.isNotBlank(fd.customLogic)) {
            return evaluateCustomLogic(fd.customLogic, results);
        }

        // Fallback to AND
        for (Boolean r : results) { if (!r) return false; }
        return true;
    }

    /**
     * Returns the set of all field API names referenced in the filter JSON.
     * Used by RollupEngine to ensure these fields are included in the bulk SOQL.
     */
    public static Set<String> getRequiredFields(String filterJson) {
        Set<String> fields = new Set<String>();
        if (String.isBlank(filterJson)) return fields;
        try {
            FilterDef fd = (FilterDef) JSON.deserialize(filterJson, FilterDef.class);
            if (fd == null || fd.conditions == null) return fields;
            for (Condition c : fd.conditions) {
                if (String.isNotBlank(c.field) && !c.field.endsWith('.')) {
                    // Keep the full dot-notation path — SOQL supports relationship
                    // traversal in SELECT e.g. "Product2.IsActive", "Account.Type"
                    // Do NOT strip to root — that caused "No such column 'product2'" error
                    fields.add(c.field.toLowerCase());
                }
            }
        } catch (Exception e) { /* ignore */ }
        return fields;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Single condition evaluator
    // ─────────────────────────────────────────────────────────────────────────

    private static Boolean evaluateCondition(SObject record, Condition c) {
        if (c == null || String.isBlank(c.field) || c.field.endsWith('.')) return true;

        String op    = String.isNotBlank(c.operator) ? c.operator.toLowerCase() : '==';
        String fType = String.isNotBlank(c.fieldType) ? c.fieldType.toUpperCase() : 'STRING';
        String filterVal = c.value != null ? c.value : '';

        // Get the actual field value from the record
        Object rawVal = getFieldValue(record, c.field);

        // IS BLANK / IS NOT BLANK
        if (op == 'isblank')    return rawVal == null || String.valueOf(rawVal).trim() == '';
        if (op == 'isnotblank') return rawVal != null && String.valueOf(rawVal).trim() != '';

        if (rawVal == null) return false; // null never matches an equality/comparison

        // BOOLEAN
        if (fType == 'BOOLEAN') {
            Boolean recBool    = Boolean.valueOf(String.valueOf(rawVal));
            Boolean filterBool = filterVal.toLowerCase() == 'true';
            if (op == '==') return recBool == filterBool;
            if (op == '!=') return recBool != filterBool;
            return false;
        }

        // DATE / DATETIME
        if (fType == 'DATE' || fType == 'DATETIME') {
            return evaluateDateCondition(rawVal, op, filterVal, fType);
        }

        // NUMERIC
        if (fType == 'DOUBLE' || fType == 'CURRENCY' || fType == 'INTEGER'
            || fType == 'LONG'  || fType == 'PERCENT') {
            return evaluateNumericCondition(rawVal, op, filterVal);
        }

        // IN list
        if (op == 'in') {
            String recStr = String.valueOf(rawVal).toLowerCase();
            for (String item : filterVal.split(',')) {
                if (item.trim().toLowerCase() == recStr) return true;
            }
            return false;
        }

        // STRING / PICKLIST / everything else
        String recStr    = String.valueOf(rawVal).toLowerCase();
        String filterStr = filterVal.toLowerCase();

        if (op == '==')       return recStr == filterStr;
        if (op == '!=')       return recStr != filterStr;
        if (op == 'contains') return recStr.contains(filterStr);
        if (op == '>')        return String.valueOf(rawVal) > filterVal;
        if (op == '<')        return String.valueOf(rawVal) < filterVal;
        if (op == '>=')       return String.valueOf(rawVal) >= filterVal;
        if (op == '<=')       return String.valueOf(rawVal) <= filterVal;

        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Date condition
    // ─────────────────────────────────────────────────────────────────────────

    private static Boolean evaluateDateCondition(Object rawVal, String op, String filterVal, String fType) {
        try {
            Date today = Date.today();

            if (op == 'last_n_days') {
                Integer n = Integer.valueOf(filterVal);
                Date cutoff = today.addDays(-n);
                Date recDate = fType == 'DATE' ? (Date) rawVal : ((DateTime) rawVal).date();
                return recDate >= cutoff && recDate <= today;
            }
            if (op == 'next_n_days') {
                Integer n = Integer.valueOf(filterVal);
                Date cutoff = today.addDays(n);
                Date recDate = fType == 'DATE' ? (Date) rawVal : ((DateTime) rawVal).date();
                return recDate >= today && recDate <= cutoff;
            }

            Date recDate    = fType == 'DATE' ? (Date) rawVal : ((DateTime) rawVal).date();
            Date filterDate = Date.valueOf(filterVal);

            if (op == '==') return recDate == filterDate;
            if (op == '!=') return recDate != filterDate;
            if (op == '>')  return recDate > filterDate;
            if (op == '<')  return recDate < filterDate;
            if (op == '>=') return recDate >= filterDate;
            if (op == '<=') return recDate <= filterDate;
        } catch (Exception e) { /* bad date value — skip */ }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Numeric condition
    // ─────────────────────────────────────────────────────────────────────────

    private static Boolean evaluateNumericCondition(Object rawVal, String op, String filterVal) {
        try {
            Decimal recDec    = Decimal.valueOf(String.valueOf(rawVal));
            Decimal filterDec = Decimal.valueOf(filterVal);

            if (op == '==') return recDec == filterDec;
            if (op == '!=') return recDec != filterDec;
            if (op == '>')  return recDec > filterDec;
            if (op == '<')  return recDec < filterDec;
            if (op == '>=') return recDec >= filterDec;
            if (op == '<=') return recDec <= filterDec;
        } catch (Exception e) { /* bad numeric value — skip */ }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Custom logic evaluator  e.g. "1 AND (2 OR 3)"
    // ─────────────────────────────────────────────────────────────────────────

    private static Boolean evaluateCustomLogic(String expr, List<Boolean> results) {
        try {
            List<String> tokens = tokenize(expr.toUpperCase());
            List<Object> postfix = toPostfix(tokens);
            return evaluatePostfix(postfix, results);
        } catch (Exception e) {
            // Fallback to AND if custom logic can't be parsed
            for (Boolean r : results) { if (!r) return false; }
            return true;
        }
    }

    // Shunting-yard tokenizer
    private static List<String> tokenize(String expr) {
        List<String> tokens = new List<String>();
        Integer i = 0;
        while (i < expr.length()) {
            String ch = expr.substring(i, i + 1);
            if (ch == ' ') { i++; continue; }
            if (ch == '(' || ch == ')') { tokens.add(ch); i++; continue; }
            if (ch >= '0' && ch <= '9') {
                String num = '';
                while (i < expr.length() && expr.substring(i, i+1) >= '0' && expr.substring(i, i+1) <= '9') {
                    num += expr.substring(i, i+1); i++;
                }
                tokens.add(num); continue;
            }
            // Word (AND / OR / NOT)
            String word = '';
            while (i < expr.length()) {
                String c2 = expr.substring(i, i+1);
                if (c2 == ' ' || c2 == '(' || c2 == ')') break;
                word += c2; i++;
            }
            if (String.isNotBlank(word)) tokens.add(word);
        }
        return tokens;
    }

    // Shunting-yard algorithm → postfix
    private static List<Object> toPostfix(List<String> tokens) {
        List<Object> output = new List<Object>();
        List<String> opStack = new List<String>();
        Map<String,Integer> prec = new Map<String,Integer>{ 'NOT'=>3, 'AND'=>2, 'OR'=>1 };

        for (String tk : tokens) {
            if (tk == '(') {
                opStack.add(tk);
            } else if (tk == ')') {
                while (!opStack.isEmpty() && opStack[opStack.size()-1] != '(') {
                    output.add(opStack.remove(opStack.size()-1));
                }
                if (!opStack.isEmpty()) opStack.remove(opStack.size()-1); // pop (
            } else if (prec.containsKey(tk)) {
                while (!opStack.isEmpty() && prec.containsKey(opStack[opStack.size()-1])
                       && prec.get(opStack[opStack.size()-1]) >= prec.get(tk)) {
                    output.add(opStack.remove(opStack.size()-1));
                }
                opStack.add(tk);
            } else {
                // number → condition index
                output.add(Integer.valueOf(tk));
            }
        }
        while (!opStack.isEmpty()) output.add(opStack.remove(opStack.size()-1));
        return output;
    }

    // Evaluate postfix expression
    private static Boolean evaluatePostfix(List<Object> postfix, List<Boolean> results) {
        List<Boolean> stack = new List<Boolean>();
        for (Object token : postfix) {
            if (token instanceof Integer) {
                Integer idx = (Integer) token - 1; // 1-based → 0-based
                stack.add(idx >= 0 && idx < results.size() ? results[idx] : false);
            } else {
                String op = (String) token;
                if (op == 'NOT') {
                    Boolean a = stack.remove(stack.size()-1);
                    stack.add(!a);
                } else {
                    Boolean b = stack.remove(stack.size()-1);
                    Boolean a = stack.remove(stack.size()-1);
                    stack.add(op == 'AND' ? (a && b) : (a || b));
                }
            }
        }
        return stack.isEmpty() ? true : stack[0];
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Field value resolver (supports relationship traversal e.g. Account.Type)
    // ─────────────────────────────────────────────────────────────────────────

    private static Object getFieldValue(SObject record, String fieldPath) {
        if (record == null || String.isBlank(fieldPath)) return null;
        try {
            if (!fieldPath.contains('.')) {
                return record.get(fieldPath);
            }
            // Traverse relationship: e.g. "Account.Type" → getSObject('Account').get('Type')
            List<String> parts = fieldPath.split('\\.');
            SObject current = record;
            for (Integer i = 0; i < parts.size() - 1; i++) {
                current = current.getSObject(parts[i]);
                if (current == null) return null;
            }
            return current.get(parts[parts.size() - 1]);
        } catch (Exception e) {
            return null;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Deserialize shapes
    // ─────────────────────────────────────────────────────────────────────────

    public class FilterDef {
        public String          logic;
        public String          customLogic;
        public List<Condition> conditions;
    }

    public class Condition {
        public String field;
        public String fieldType;
        public String operator;
        public String value;
    }
}