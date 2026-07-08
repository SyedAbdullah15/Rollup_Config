import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectOptions   from '@salesforce/apex/RollupConfigController.getObjectOptions';
import getLookupFields    from '@salesforce/apex/RollupConfigController.getLookupFields';
import getFields          from '@salesforce/apex/RollupConfigController.getFields';
import getConfig          from '@salesforce/apex/RollupConfigController.getConfig';
import getConfigById      from '@salesforce/apex/RollupConfigController.getConfigById';
import getConditionFields from '@salesforce/apex/RollupConfigController.getConditionFields';
import saveConfig         from '@salesforce/apex/RollupConfigController.saveConfig';
import recalculateAll    from '@salesforce/apex/RollupConfigController.recalculateAll';

const NUMERIC = ['DOUBLE','CURRENCY','INTEGER','LONG','PERCENT'];
const DATEISH = ['DATE','DATETIME'];
const TEXTISH  = ['STRING','TEXTAREA','EMAIL','PHONE','URL','PICKLIST'];

const OPERATIONS = [
    { label:'Sum',         value:'Sum'    },
    { label:'Count',       value:'Count'  },
    { label:'Min',         value:'Min'    },
    { label:'Max',         value:'Max'    },
    { label:'Average',     value:'Avg'    },
    { label:'Concatenate', value:'Concat' }
];

const MODES = [
    { label:'Real-time (Flow/trigger)',     value:'Realtime'  },
    { label:'Queueable (async, ~5s delay)', value:'Queueable' },
    { label:'Scheduled (batch)',            value:'Scheduled' }
];

export default class RollupConfigurator extends LightningElement {
    @api recordId;               // present on a Rollup_Config__c record page
    @track objectApi   = '';
    @track active      = true;
    @track rules       = [];      // raw rule records (in-memory until Save)
    @track loading     = false;
    @track saving      = false;
    @track objectError   = '';    // shown when object API name can't be resolved
    @track recalculating = false; // true while batch is being enqueued
    @track isEditMode    = false; // true when in edit mode, false = read-only view
    _configId = null;             // the Rollup_Config__c being edited (record mode)

    objectOptions = [];
    _lookupFields = [];          // lookup fields on the source object
    _sourceFields = [];          // all fields on the source object
    _parentFieldsByObj = {};     // parentObject api -> [fields] (for Target picker)
    _fieldsVersion = 0;          // bump to re-render after async loads

    operationOptions = OPERATIONS;
    modeOptions      = MODES;

    // ── Filter builder (structured conditions, per rule) ──
    @track showFilterModal    = false;
    @track condFieldsByObject = {};
    @track condFieldsVersion  = 0;
    _filterRuleIndex = null;

    // ─────────────────────────────────────────────────────────────────────────
    //  Lifecycle
    // ─────────────────────────────────────────────────────────────────────────
    connectedCallback() {
        if (this.recordId) {
            this.loading = true;
            getConfigById({ recordId: this.recordId })
                .then(cfg => {
                    if (!cfg || !cfg.applicableObject) {
                        this.objectError = 'No applicable object found on this configuration record. The object may have been deleted or the record is misconfigured.';
                        this.loading = false;
                        return;
                    }
                    this._applyConfig(cfg);
                })
                .catch(e => { this._toast('Error', this._msg(e), 'error'); this.loading = false; });
        } else {
            getObjectOptions()
                .then(opts => {
                    this.objectOptions = opts || [];
                    if (!this.objectOptions.length) {
                        this.objectError = 'No accessible objects found. You may not have the required permissions to view Salesforce objects.';
                    }
                })
                .catch(e => {
                    this.objectError = 'Failed to load objects: ' + this._msg(e);
                    this._toast('Error', this._msg(e), 'error');
                });
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Computed getters
    // ─────────────────────────────────────────────────────────────────────────
    get isRecordMode()          { return !!this.recordId; }
    get isViewMode()            { return !this.isEditMode; }
    get showRecalcButton()      { return !!this._configId && !this.objectError; }
    get recalcDisabled()        { return this.recalculating || this.saving; }
    get activeLabel()           { return this.active ? 'Active' : 'Inactive'; }
    get activeBadgeClass()      { return this.active ? 'rc-status-badge rc-status-active' : 'rc-status-badge rc-status-inactive'; }
    get hasObject()       { return !!this.objectApi && !this.objectError; }
    get hasObjectError()  { return !!this.objectError; }
    get saveDisabled()    { return !this.objectApi || this.saving || !!this.objectError; }
    get objectDisplay() {
        const opt = this.objectOptions.find(o => o.value === this.objectApi);
        return opt ? opt.label : this.objectApi;
    }
    get noObjectOptions() { return !this.loading && this.objectOptions.length === 0 && !this.isRecordMode; }
    get noLookupFields()  { return !this.loading && this.objectApi && this._lookupFields.length === 0 && !this.objectError; }

    // ─────────────────────────────────────────────────────────────────────────
    //  Config loading
    // ─────────────────────────────────────────────────────────────────────────
    _applyConfig(cfg) {
        this.objectError = '';
        this._configId = cfg && cfg.configId ? cfg.configId : null;
        this.objectApi = cfg && cfg.applicableObject ? cfg.applicableObject : this.objectApi;
        this.active    = cfg ? !!cfg.active : true;
        this.rules     = (cfg && cfg.rules ? cfg.rules : []).map(r => this._fromDto(r));
        // Start in edit mode if no existing config, view mode if loading existing
        this.isEditMode = !this._configId;
        if (!this.objectApi) {
            this.objectError = 'No object API name found. Please select a valid object.';
            this.loading = false;
            return;
        }
        this.loading = true;
        Promise.all([
            getLookupFields({ objectApiName: this.objectApi }),
            getFields({ objectApiName: this.objectApi })
        ]).then(([lookups, fields]) => {
            this._lookupFields = lookups || [];
            this._sourceFields = fields || [];
            if (!this._lookupFields.length && !this._sourceFields.length) {
                this.objectError = `"${this.objectApi}" does not appear to be a valid or accessible object. Check that the API name is correct and you have permission to access it.`;
            }
            const parents = [...new Set(this.rules.map(r => r.parentObject).filter(Boolean))];
            return Promise.all(parents.map(p => this._loadParentFields(p)));
        }).catch(e => {
            this.objectError = `Could not load fields for "${this.objectApi}". The object may not exist or you may not have access. (${this._msg(e)})`;
            this._toast('Error', this._msg(e), 'error');
        }).finally(() => { this.loading = false; });
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Object selection (standalone mode only)
    // ─────────────────────────────────────────────────────────────────────────
    handleObjectChange(e) {
        this.objectApi    = e.detail.value;
        this.objectError  = '';
        this._configId    = null;
        this.isEditMode   = true; // always start in edit mode when selecting a new object
        if (!this.objectApi) { this.rules = []; return; }
        getConfig({ objectApiName: this.objectApi })
            .then(cfg => this._applyConfig(cfg || { applicableObject: this.objectApi, active: true, rules: [] }))
            .catch(e => {
                this.objectError = `Failed to load configuration for "${this.objectApi}": ${this._msg(e)}`;
                this._toast('Error', this._msg(e), 'error');
            });
    }

    handleActiveToggle(e) { this.active = e.target.checked; }

    handleEdit() { this.isEditMode = true; }

    handleCancel() {
        this.isEditMode = false;
        // Revert unsaved changes by reloading from server
        this._reloadConfig();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Rules
    // ─────────────────────────────────────────────────────────────────────────
    _blankRule() {
        return {
            lookupField:'', parentObject:'', operation:'Sum', sourceField:'',
            targetField:'', filter:{ logic:'AND', customLogic:'', conditions:[] },
            concatDelimiter:', ', mode:'Realtime', active:true
        };
    }

    _fromDto(r) {
        let filter = { logic:'AND', customLogic:'', conditions:[] };
        if (r.filterCriteria) {
            try {
                const p = JSON.parse(r.filterCriteria);
                if (p && typeof p === 'object' && Array.isArray(p.conditions)) {
                    filter = { logic: p.logic || 'AND', customLogic: p.customLogic || '', conditions: p.conditions };
                }
            } catch (e) { /* legacy free-text — dropped safely */ }
        }
        return {
            lookupField:     r.lookupField     || '',
            parentObject:    r.parentObject    || '',
            operation:       r.operation       || 'Sum',
            sourceField:     r.sourceField     || '',
            targetField:     r.targetField     || '',
            filter,
            concatDelimiter: r.concatDelimiter || ', ',
            mode:            r.mode            || 'Realtime',
            active:          r.active === undefined ? true : !!r.active
        };
    }

    handleAddRule()  { this.rules = [...this.rules, this._blankRule()]; }
    handleRemoveRule(e) {
        const i = parseInt(e.currentTarget.dataset.index, 10);
        this.rules = this.rules.filter((_, idx) => idx !== i);
    }

    handleRuleChange(e) {
        const i     = parseInt(e.currentTarget.dataset.index, 10);
        const field = e.currentTarget.dataset.field;
        const val   = (e.detail && e.detail.value !== undefined) ? e.detail.value
                    : (e.target.type === 'checkbox' ? e.target.checked : e.target.value);
        const rules = this.rules.map(r => ({ ...r }));
        const rule  = rules[i];
        if (!rule) return;
        rule[field] = val;

        if (field === 'lookupField') {
            const lk = this._lookupFields.find(l => l.apiName === val);
            rule.parentObject = lk ? lk.referenceTo : '';
            rule.targetField  = '';
            if (rule.parentObject) this._loadParentFields(rule.parentObject);
        }
        if (field === 'operation') {
            rule.sourceField = '';
        }
        this.rules = rules;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Parent field loader
    // ─────────────────────────────────────────────────────────────────────────
    _loadParentFields(parentObj) {
        if (!parentObj || this._parentFieldsByObj[parentObj]) return Promise.resolve();
        return getFields({ objectApiName: parentObj })
            .then(fs => { this._parentFieldsByObj[parentObj] = fs || []; this._fieldsVersion++; })
            .catch(e => this._toast('Error', this._msg(e), 'error'));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Rule view-model
    // ─────────────────────────────────────────────────────────────────────────
    _typeOk(type, op, isTarget) {
        type = (type || '').toUpperCase();
        if (op === 'Concat') return isTarget ? TEXTISH.includes(type) : true;
        if (op === 'Count')  return NUMERIC.includes(type);
        if (op === 'Sum' || op === 'Avg') return NUMERIC.includes(type);
        if (op === 'Min' || op === 'Max') return NUMERIC.includes(type) || DATEISH.includes(type);
        return true;
    }

    get lookupOptions() {
        return this._lookupFields.map(l => ({ label: `${l.label} → ${l.referenceTo}`, value: l.apiName }));
    }

    get ruleRows() {
        const _v = this._fieldsVersion; // reactive touch
        return this.rules.map((r, i) => {
            const op       = r.operation || 'Sum';
            const isCount  = op === 'Count';
            const isConcat = op === 'Concat';
            const srcOpts  = this._sourceFields
                .filter(f => this._typeOk(f.type, op, false))
                .map(f => ({ label: f.label, value: f.apiName }));
            const tgtOpts  = (this._parentFieldsByObj[r.parentObject] || [])
                .filter(f => this._typeOk(f.type, op, true))
                .map(f => ({ label: f.label, value: f.apiName }));
            const condCount = (r.filter && r.filter.conditions) ? r.filter.conditions.length : 0;
            return {
                key:              `rule-${i}`,
                index:            i,
                num:              i + 1,
                lookupField:      r.lookupField,
                parentObject:     r.parentObject,
                parentBadge:      r.parentObject ? `Parent: ${r.parentObject}` : 'Pick a lookup field →',
                operation:        r.operation,
                sourceField:      r.sourceField,
                targetField:      r.targetField,
                filterSummary:    condCount ? `${condCount} condition${condCount > 1 ? 's' : ''}` : 'No filter — all records',
                concatDelimiter:  r.concatDelimiter,
                mode:             r.mode,
                active:           r.active,
                sourceOptions:    srcOpts,
                targetOptions:    tgtOpts,
                showSource:       !isCount,
                showDelimiter:    isConcat,
                targetDisabled:   !r.parentObject,
                showQueueableHint: r.mode === 'Queueable',
                // View-mode display labels
                lookupLabel:      r.lookupField  || '—',
                operationLabel:   r.operation    || '—',
                sourceLabel:      r.sourceField  || (isCount ? 'N/A (Count)' : '—'),
                targetLabel:      r.targetField  || '—',
                modeLabel:        r.mode         || '—',
                activeLabel:      r.active ? 'Active' : 'Inactive',
                activeBadgeClass: r.active ? 'rc-rule-badge rc-rule-active-badge' : 'rc-rule-badge rc-rule-inactive-badge'
            };
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Save
    // ─────────────────────────────────────────────────────────────────────────
    handleSave() {
        const err = this._validate();
        if (err) { this._toast('Incomplete', err, 'warning'); return; }
        this.saving = true;
        const dto = this.rules.map(r => ({
            lookupField:     r.lookupField,
            parentObject:    r.parentObject,
            operation:       r.operation,
            sourceField:     r.sourceField,
            targetField:     r.targetField,
            filterCriteria:  JSON.stringify(r.filter || { logic:'AND', customLogic:'', conditions:[] }),
            concatDelimiter: r.concatDelimiter,
            mode:            r.mode,
            active:          r.active
        }));
        saveConfig({
            objectApiName: this.objectApi,
            active:        this.active,
            rulesJson:     JSON.stringify(dto),
            configId:      this._configId
        })
            .then(() => {
                this._toast('Saved', 'Rollup configuration saved.', 'success');
                this.isEditMode = false; // switch back to view mode after save
                return this._reloadConfig();
            })
            .catch(e => this._toast('Save failed', this._msg(e), 'error'))
            .finally(() => { this.saving = false; });
    }

    // Re-fetch the config from Apex after any DML operation
    _reloadConfig() {
        if (this._configId) {
            return getConfigById({ recordId: this._configId })
                .then(cfg => {
                    if (cfg) {
                        this._configId = cfg.configId || this._configId;
                        this.active    = !!cfg.active;
                        this.rules     = (cfg.rules || []).map(r => this._fromDto(r));
                    }
                })
                .catch(e => this._toast('Refresh error', this._msg(e), 'error'));
        } else if (this.objectApi) {
            return getConfig({ objectApiName: this.objectApi })
                .then(cfg => {
                    if (cfg && cfg.configId) {
                        this._configId = cfg.configId;
                        this.active    = !!cfg.active;
                        this.rules     = (cfg.rules || []).map(r => this._fromDto(r));
                    }
                })
                .catch(e => this._toast('Refresh error', this._msg(e), 'error'));
        }
        return Promise.resolve();
    }

    _validate() {
        if (!this.rules.length) return 'Add at least one rollup rule.';
        for (let i = 0; i < this.rules.length; i++) {
            const r = this.rules[i];
            const n = i + 1;
            if (!r.lookupField)                       return `Rule ${n}: choose a lookup field.`;
            if (!r.targetField)                       return `Rule ${n}: choose a target field.`;
            if (r.operation !== 'Count' && !r.sourceField) return `Rule ${n}: choose a source field.`;
        }
        return '';
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILTER BUILDER — structured conditions per rule
    //  (type-aware values, picklist/boolean dropdowns, date + relative ranges,
    //   relationship drill-down, AND/OR/Custom logic)
    // ═════════════════════════════════════════════════════════════════════════

    _filterObj() {
        const r = this.rules[this._filterRuleIndex];
        return (r && r.filter) ? r.filter : { logic:'AND', customLogic:'', conditions:[] };
    }

    _patchFilter(next) {
        const idx = this._filterRuleIndex;
        if (idx == null) return;
        const rules = this.rules.map(r => ({ ...r }));
        const cur   = rules[idx].filter || { logic:'AND', customLogic:'', conditions:[] };
        rules[idx].filter = {
            logic:       next.logic       !== undefined ? next.logic       : (cur.logic       || 'AND'),
            customLogic: next.customLogic !== undefined ? next.customLogic : (cur.customLogic || ''),
            conditions:  next.conditions  !== undefined ? next.conditions  : (cur.conditions  || []).map(c => ({ ...c }))
        };
        this.rules = rules;
    }

    _blankCond() {
        return { field:'', drillObject: this.objectApi, pathLabel:'', fieldType:'', picklistValues:[], operator:'==', value:'' };
    }

    // ── Modal open/close ──
    handleOpenFilterModal(e) {
        this._filterRuleIndex = parseInt(e.currentTarget.dataset.index, 10);
        this.showFilterModal  = true;
        this._loadCondFields(this.objectApi);
        (this._filterObj().conditions || []).forEach(c => { if (c.drillObject) this._loadCondFields(c.drillObject); });
    }

    handleCloseFilterModal() {
        if (this.isFilterCustom) {
            const err = this._validateCustomLogic(this._filterObj().customLogic, this.filterConditionCount);
            if (err) { this._toast('Invalid custom logic', err, 'error'); return; }
        }
        this.showFilterModal  = false;
        this._filterRuleIndex = null;
    }

    handleFilterModalBackdrop(e) { if (e.target === e.currentTarget) this.handleCloseFilterModal(); }

    // ── Logic ──
    get filterLogic()        { return this._filterObj().logic || 'AND'; }
    get filterCustomLogic()  { return this._filterObj().customLogic || ''; }
    get isFilterCustom()     { return this.filterLogic === 'CUSTOM'; }
    get filterRuleNumber()   { return this._filterRuleIndex != null ? this._filterRuleIndex + 1 : ''; }
    get filterLogicOptions() {
        return [
            { label:'ALL conditions (AND)',    value:'AND'    },
            { label:'ANY condition (OR)',       value:'OR'     },
            { label:'Custom logic (advanced)', value:'CUSTOM' }
        ];
    }
    get filterCustomError()    { return this.isFilterCustom ? this._validateCustomLogic(this._filterObj().customLogic, this.filterConditionCount) : ''; }
    get hasFilterCustomError() { return !!this.filterCustomError; }

    handleFilterLogicChange(e) {
        const logic = e.detail.value;
        let customLogic = this._filterObj().customLogic || '';
        if (logic === 'CUSTOM' && !customLogic) {
            const n = this.filterConditionCount;
            customLogic = n > 0 ? Array.from({ length: n }, (_, i) => i + 1).join(' AND ') : '1';
        }
        this._patchFilter({ logic, customLogic });
    }

    handleFilterCustomLogicChange(e) { this._patchFilter({ customLogic: e.target.value }); }

    // ── Conditions ──
    get filterConditionCount() { return (this._filterObj().conditions || []).length; }

    handleAddFilterCondition() {
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c }));
        conditions.push(this._blankCond());
        this._patchFilter({ conditions });
    }

    handleRemoveFilterCondition(e) {
        const idx        = parseInt(e.currentTarget.dataset.index, 10);
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c })).filter((_, i) => i !== idx);
        this._patchFilter({ conditions });
    }

    handleFilterFieldChange(e) {
        const idx    = parseInt(e.currentTarget.dataset.index, 10);
        const picked = e.detail.value;
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c }));
        const c = conditions[idx];
        if (!c) return;
        const drillObj = c.drillObject || this.objectApi;
        const meta     = this._condFieldMeta(drillObj, picked);
        if (!meta) return;
        const prefix = (c.field && c.field.endsWith('.'))       ? c.field
                     : (c.field && c.field.includes('.'))        ? c.field.slice(0, c.field.lastIndexOf('.') + 1)
                     : '';
        if (meta.isReference) {
            c.field       = `${prefix}${meta.relationshipName}.`;
            c.drillObject = meta.referenceTo;
            c.pathLabel   = (c.pathLabel ? `${c.pathLabel} ▸ ` : '') + meta.label;
            c.fieldType   = ''; c.picklistValues = [];
            this._loadCondFields(meta.referenceTo);
        } else {
            c.field          = `${prefix}${meta.apiName}`;
            c.fieldType      = meta.type;
            c.picklistValues = meta.picklistValues || [];
            const ops = this._operatorOptionsFor(meta.type);
            if (!ops.some(o => o.value === c.operator)) c.operator = ops[0].value;
            if (this._noValueOp(c.operator)) c.value = '';
            if (this._isBooleanType(meta.type) && !c.value) c.value = 'true';
        }
        this._patchFilter({ conditions });
    }

    handleFilterFieldReset(e) {
        const idx        = parseInt(e.currentTarget.dataset.index, 10);
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c }));
        if (conditions[idx]) Object.assign(conditions[idx], { field:'', drillObject: this.objectApi, pathLabel:'', fieldType:'', picklistValues:[], value:'' });
        this._patchFilter({ conditions });
    }

    handleFilterOperatorChange(e) {
        const idx        = parseInt(e.currentTarget.dataset.index, 10);
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c }));
        if (conditions[idx]) {
            conditions[idx].operator = e.detail.value;
            if (this._noValueOp(e.detail.value)) conditions[idx].value = '';
        }
        this._patchFilter({ conditions });
    }

    handleFilterValueChange(e) {
        const idx        = parseInt(e.currentTarget.dataset.index, 10);
        const v          = (e.detail && e.detail.value !== undefined) ? e.detail.value : e.target.value;
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c }));
        if (conditions[idx]) conditions[idx].value = v;
        this._patchFilter({ conditions });
    }

    handleFilterRelativePreset(e) {
        const idx        = parseInt(e.currentTarget.dataset.index, 10);
        const n          = e.currentTarget.dataset.n;
        const conditions = (this._filterObj().conditions || []).map(c => ({ ...c }));
        if (conditions[idx]) conditions[idx].value = String(n);
        this._patchFilter({ conditions });
    }

    get filterRelativePresets() { return [7,15,30,90].map(n => ({ key:`p${n}`, n })); }

    // ── Type helpers ──
    _noValueOp(op)     { return op === 'isblank' || op === 'isnotblank'; }
    _isDateType(t)     { t=(t||'').toUpperCase(); return t==='DATE' || t==='DATETIME'; }
    _isPicklistType(t) { t=(t||'').toUpperCase(); return t==='PICKLIST' || t==='MULTIPICKLIST'; }
    _isBooleanType(t)  { t=(t||'').toUpperCase(); return t==='BOOLEAN'; }

    _operatorOptionsFor(type) {
        if (this._isBooleanType(type)) {
            return [ { label:'equals', value:'==' }, { label:'not equals', value:'!=' } ];
        }
        if (this._isDateType(type)) {
            return [
                { label:'on (=)',             value:'=='          },
                { label:'not on (≠)',         value:'!='          },
                { label:'after (>)',          value:'>'           },
                { label:'before (<)',         value:'<'           },
                { label:'on or after (>=)',   value:'>='          },
                { label:'on or before (<=)',  value:'<='          },
                { label:'in the last N days', value:'last_n_days' },
                { label:'in the next N days', value:'next_n_days' },
                { label:'is blank',           value:'isblank'     },
                { label:'is not blank',       value:'isnotblank'  }
            ];
        }
        if (this._isPicklistType(type)) {
            return [
                { label:'equals',            value:'=='       },
                { label:'not equals',        value:'!='       },
                { label:'is any of (IN)',    value:'in'       },
                { label:'is blank',          value:'isblank'  },
                { label:'is not blank',      value:'isnotblank' }
            ];
        }
        return [
            { label:'equals',             value:'=='        },
            { label:'not equals',         value:'!='        },
            { label:'contains',           value:'contains'  },
            { label:'is blank',           value:'isblank'   },
            { label:'is not blank',       value:'isnotblank'},
            { label:'greater than (>)',   value:'>'         },
            { label:'less than (<)',      value:'<'         },
            { label:'greater or equal (>=)', value:'>='    },
            { label:'less or equal (<=)', value:'<='        },
            { label:'is any of (IN)',     value:'in'        }
        ];
    }

    // ── Field metadata cache ──
    _condFields(objApi)          { return this.condFieldsByObject[objApi] || []; }
    _condFieldMeta(objApi, name) { return this._condFields(objApi).find(f => (f.apiName||'').toLowerCase() === (name||'').toLowerCase()) || null; }

    _loadCondFields(objApi) {
        if (!objApi || this.condFieldsByObject[objApi]) return Promise.resolve();
        return getConditionFields({ objectApiName: objApi })
            .then(list => {
                this.condFieldsByObject = { ...this.condFieldsByObject, [objApi]: list || [] };
                this.condFieldsVersion++;
            })
            .catch(e => this._toast('Field load error', this._msg(e), 'error'));
    }

    _condFieldOptions(objApi) {
        return this._condFields(objApi).map(f => ({ label: f.isReference ? `${f.label}  ▸` : f.label, value: f.apiName }));
    }

    _condTerminalApi(c) {
        const f = c.field || '';
        if (!f || f.endsWith('.')) return '';
        return f.includes('.') ? f.slice(f.lastIndexOf('.') + 1) : f;
    }

    // ── Enriched condition view-model ──
    get filterConditions() {
        const _v    = this.condFieldsVersion; // reactive touch
        const conds = this._filterObj().conditions || [];
        const logic = this.filterLogic;
        return conds.map((c, i) => {
            const drillObj   = c.drillObject || this.objectApi;
            const type       = c.fieldType || '';
            const op         = c.operator  || '==';
            const isDate     = this._isDateType(type);
            const isPicklist = this._isPicklistType(type);
            const isBoolean  = this._isBooleanType(type);
            const noVal      = this._noValueOp(op);
            const isRelative = (op === 'last_n_days' || op === 'next_n_days');
            const isDatePick = isDate && !isRelative && !noVal;
            const isPickVal  = isPicklist && !noVal && (op === '==' || op === '!=');
            const isBoolVal  = isBoolean  && !noVal && (op === '==' || op === '!=');
            const isInList   = (op === 'in');
            return {
                key:    `f-${i}`, sepKey: `f-sep-${i}`, index: i, number: i + 1,
                fieldValue:      this._condTerminalApi(c),
                fieldOptions:    this._condFieldOptions(drillObj),
                pathLabel:       c.pathLabel || '',
                hasPath:         !!c.pathLabel,
                operator:        op,
                operatorOptions: this._operatorOptionsFor(type),
                needsValue:      !noVal,
                isPicklistVal:   isPickVal,
                isBooleanVal:    isBoolVal,
                isDateVal:       isDatePick,
                isRelativeVal:   isRelative,
                isInList:        isInList,
                isTextVal:       !noVal && !isPickVal && !isBoolVal && !isDatePick && !isRelative && !isInList,
                picklistValueOptions: (c.picklistValues || []).map(v => ({ label:v, value:v })),
                booleanValueOptions:  [ { label:'True', value:'true' }, { label:'False', value:'false' } ],
                value:           c.value || '',
                showLogicSep:    (logic !== 'CUSTOM') && (i < conds.length - 1)
            };
        });
    }

    // ── Preview text ──
    _condDescribe(c) {
        const f  = (c.field || '?').replace(/\.$/, '');
        const op = c.operator || '==';
        if (this._noValueOp(op)) return `${f} ${op === 'isblank' ? 'is blank' : 'is not blank'}`;
        if (op === 'last_n_days') return `${f} in last ${c.value || 'N'} days`;
        if (op === 'next_n_days') return `${f} in next ${c.value || 'N'} days`;
        const isBool = (c.fieldType || '').toUpperCase() === 'BOOLEAN';
        const v = (op === 'in') ? `[${c.value || ''}]`
                : isBool        ? (c.value || 'false')
                : `'${c.value || ''}'`;
        return `${f} ${op} ${v}`;
    }

    get filterPreviewText() {
        const conds = this._filterObj().conditions || [];
        if (!conds.length) return '(no conditions yet — all child records included)';
        if (this.filterLogic === 'CUSTOM') {
            const expr = this._filterObj().customLogic || '';
            if (!expr.trim()) return '(empty custom logic)';
            const { tokens } = this._tokenizeLogic(expr);
            if (!tokens) return expr;
            return tokens.map(tk => {
                if (tk.t === 'NUM') { const c = conds[tk.v - 1]; return c ? this._condDescribe(c) : `#${tk.v}`; }
                if (tk.t === '(') return '(';
                if (tk.t === ')') return ')';
                return tk.t;
            }).join(' ').replace(/\(\s+/g, '(').replace(/\s+\)/g, ')');
        }
        return conds.map(c => this._condDescribe(c)).join(` ${this.filterLogic} `);
    }

    // ── Custom-logic tokenizer + validator ──
    _tokenizeLogic(expr) {
        const s = (expr || '').toUpperCase();
        const tokens = []; let i = 0;
        while (i < s.length) {
            const ch = s[i];
            if (ch === ' ' || ch === '\t') { i++; continue; }
            if (ch === '(') { tokens.push({ t:'(' }); i++; continue; }
            if (ch === ')') { tokens.push({ t:')' }); i++; continue; }
            if (ch >= '0' && ch <= '9') {
                let num = '';
                while (i < s.length && s[i] >= '0' && s[i] <= '9') { num += s[i]; i++; }
                tokens.push({ t:'NUM', v: parseInt(num, 10) });
                continue;
            }
            if (ch >= 'A' && ch <= 'Z') {
                let w = '';
                while (i < s.length && s[i] >= 'A' && s[i] <= 'Z') { w += s[i]; i++; }
                if (w === 'AND' || w === 'OR' || w === 'NOT') tokens.push({ t: w });
                else return { tokens: null, error: `Unexpected word "${w}". Use AND, OR, NOT, ( ), and condition numbers.` };
                continue;
            }
            return { tokens: null, error: `Unexpected character "${ch}".` };
        }
        return { tokens, error: '' };
    }

    _validateCustomLogic(expr, n) {
        if (!expr || !expr.trim()) return 'Enter a logic expression, e.g. 1 AND (2 OR 3).';
        const { tokens, error } = this._tokenizeLogic(expr);
        if (error) return error;
        if (!tokens.length) return 'Enter a logic expression, e.g. 1 AND (2 OR 3).';
        for (const tk of tokens) {
            if (tk.t === 'NUM' && (tk.v < 1 || tk.v > n))
                return `Condition ${tk.v} doesn't exist (you have ${n} condition${n === 1 ? '' : 's'}).`;
        }
        let depth = 0, expectOperand = true;
        for (const tk of tokens) {
            if (expectOperand) {
                if (tk.t === 'NOT') continue;
                if (tk.t === '(')  { depth++; continue; }
                if (tk.t === 'NUM') { expectOperand = false; continue; }
                return 'Expected a condition number, NOT, or "(".';
            } else {
                if (tk.t === 'AND' || tk.t === 'OR') { expectOperand = true; continue; }
                if (tk.t === ')') { depth--; if (depth < 0) return 'Unbalanced parentheses.'; continue; }
                return 'Expected AND, OR, or ")".';
            }
        }
        if (expectOperand) return 'Expression ends unexpectedly — add a condition number.';
        if (depth !== 0)   return 'Unbalanced parentheses.';
        return '';
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Recalculate All — triggers RollupBatch for historical recalc
    // ─────────────────────────────────────────────────────────────────────────
    handleRecalculateAll() {
        if (!this._configId) {
            this._toast('Save First', 'Please save the configuration before recalculating.', 'warning');
            return;
        }
        this.recalculating = true;
        recalculateAll({ configId: this._configId })
            .then(() => {
                this._toast(
                    'Recalculation Started',
                    'The batch job is running in the background. All parent records will be updated shortly depending on record volume.',
                    'success'
                );
            })
            .catch(e => this._toast('Recalculation Failed', this._msg(e), 'error'))
            .finally(() => { this.recalculating = false; });
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Utilities
    // ─────────────────────────────────────────────────────────────────────────
    _toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
    stopProp(e) { e.stopPropagation(); }
    _msg(e) { return (e && e.body && e.body.message) ? e.body.message : (e && e.message) ? e.message : 'Unexpected error'; }
}