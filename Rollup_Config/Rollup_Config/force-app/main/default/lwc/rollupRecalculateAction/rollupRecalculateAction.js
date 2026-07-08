import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import recalculateAll from '@salesforce/apex/RollupConfigController.recalculateAll';

export default class RollupRecalculateAction extends LightningElement {
    @api recordId;
    isLoading = false;

    @api invoke() {}  // required for headless action — modal renders instead

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleConfirm() {
        this.isLoading = true;
        recalculateAll({ configId: this.recordId })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Recalculation Started',
                    message: 'Batch job is running in the background. All parent records will be updated shortly.',
                    variant: 'success',
                    mode:    'sticky'
                }));
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .catch(e => {
                const msg = (e && e.body && e.body.message) ? e.body.message : 'Unexpected error';
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Recalculation Failed',
                    message: msg,
                    variant: 'error',
                    mode:    'sticky'
                }));
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .finally(() => { this.isLoading = false; });
    }
}