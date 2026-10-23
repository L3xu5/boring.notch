import Testing
@testable import BoringCore

@Test func permissionRequestsCannotAdvanceAfterSkippingOrGoingBack() {
    var flow = OnboardingFlowState()
    flow.navigate(to: .calendar)
    let request = flow.beginRequest()!
    let duplicate = flow.beginRequest()
    #expect(duplicate == nil)
    flow.navigate(to: .reminders)
    let skippedResult = flow.finishRequest(request, from: .calendar, advancingTo: .reminders)
    #expect(!skippedResult)
    #expect(flow.stage == .reminders)
    flow.navigate(to: .calendar)
    let retry = flow.beginRequest()!
    let staleResult = flow.finishRequest(request, from: .calendar, advancingTo: .reminders)
    #expect(!staleResult)
    let retryResult = flow.finishRequest(retry, from: .calendar, advancingTo: .reminders)
    #expect(retryResult)
    #expect(flow.stage == .reminders)
}

@Test func deniedPermissionCanStayOnItsStageAndRetry() {
    var flow = OnboardingFlowState()
    flow.navigate(to: .camera)
    let request = flow.beginRequest()!
    let result = flow.finishRequest(request, from: .camera, advancingTo: nil)
    #expect(result)
    #expect(flow.stage == .camera)
    #expect(flow.pendingRequest == nil)
    let retry = flow.beginRequest()
    #expect(retry != nil)
}
