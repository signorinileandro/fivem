LS_DELIVERY = LS_DELIVERY or {}

LS_DELIVERY.Events = {
    RequestStart = 'ls-job-system:server:requestStart',
    RequestState = 'ls-job-system:server:requestState',
    CompleteDelivery = 'ls-job-system:server:completeDelivery',
    FinishJob = 'ls-job-system:server:finishJob',
    CancelJob = 'ls-job-system:server:cancelJob',
    SyncSession = 'ls-job-system:client:syncSession',
    DeliveryAccepted = 'ls-job-system:client:deliveryAccepted',
    RequestRejected = 'ls-job-system:client:requestRejected',
    JobFinished = 'ls-job-system:client:jobFinished',
    JobCancelled = 'ls-job-system:client:jobCancelled'
}

LS_DELIVERY.SessionStatus = {
    Delivering = 'delivering',
    AwaitingReturn = 'awaiting_return',
    Paying = 'paying'
}
