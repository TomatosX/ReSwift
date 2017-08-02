//
//  StoreSubscriptionTests.swift
//  ReSwift
//
//  Created by Benjamin Encz on 11/27/15.
//  Copyright © 2015 DigiTales. All rights reserved.
//

import XCTest
/**
 @testable import for internal testing of `Store.subscriptions`
 */
@testable import ReSwift

class StoreSubscriptionTests: XCTestCase {

    typealias TestSubscriber = TestStoreSubscriber<TestAppState>

    var store: Store<TestAppState>!
    var reducer: TestReducer!

    override func setUp() {
        super.setUp()
        reducer = TestReducer()
        store = Store(reducer: reducer.handleAction, state: TestAppState())
    }

    /**
     It does not strongly capture an observer
     */
    func testStrongCapture() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        var subscriber: TestSubscriber? = TestSubscriber()

        store.subscribe(subscriber!)
        XCTAssertEqual(store.subscriptions.flatMap({ $0.subscriber }).count, 1)

        subscriber = nil
        XCTAssertEqual(store.subscriptions.flatMap({ $0.subscriber }).count, 0)
    }

    func testRetainCycle_OriginalSubscription() {
        struct TracerAction: Action { }
        class TestSubscriptionBox<S>: SubscriptionBox<S> {
            override init<T>(
                originalSubscription: Subscription<S>,
                transformedSubscription: Subscription<T>?,
                subscriber: AnyStoreSubscriber
                ) {
                super.init(originalSubscription: originalSubscription, transformedSubscription: transformedSubscription, subscriber: subscriber)
            }
            var didDeinit: (() -> Void)?
            deinit {
                didDeinit?()
            }
        }
        class TestStore<State: StateType>: Store<State> {
            override func subscriptionBox<T>(originalSubscription: Subscription<State>, transformedSubscription: Subscription<T>?, subscriber: AnyStoreSubscriber) -> SubscriptionBox<State> {
                return TestSubscriptionBox(originalSubscription: originalSubscription, transformedSubscription: transformedSubscription, subscriber: subscriber)
            }
        }

        var didDeinit = false

        autoreleasepool {

            store = TestStore(reducer: reducer.handleAction, state: TestAppState())
            let subscriber: TestSubscriber = TestSubscriber()

            // Preconditions
            XCTAssertEqual(subscriber.receivedStates.count, 0)
            XCTAssertEqual(store.subscriptions.count, 0)

            autoreleasepool {

                store.subscribe(subscriber)
                XCTAssertEqual(subscriber.receivedStates.count, 1)
                let subscriptionBox: TestSubscriptionBox<TestAppState> = store.subscriptions.first! as! TestSubscriptionBox<TestAppState>
                subscriptionBox.didDeinit = { didDeinit = true }

                store.dispatch(TracerAction())
                XCTAssertEqual(subscriber.receivedStates.count, 2)
                store.unsubscribe(subscriber)
            }

            XCTAssertEqual(store.subscriptions.count, 0)
            store.dispatch(TracerAction())
            XCTAssertEqual(subscriber.receivedStates.count, 2)

            store = nil
        }

        XCTAssertTrue(didDeinit)
    }

    /**
     it removes deferenced subscribers before notifying state changes
     */
    func testRemoveSubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        var subscriber1: TestSubscriber? = TestSubscriber()
        var subscriber2: TestSubscriber? = TestSubscriber()

        store.subscribe(subscriber1!)
        store.subscribe(subscriber2!)
        store.dispatch(SetValueAction(3))
        XCTAssertEqual(store.subscriptions.count, 2)
        XCTAssertEqual(subscriber1?.receivedStates.last?.testValue, 3)
        XCTAssertEqual(subscriber2?.receivedStates.last?.testValue, 3)

        subscriber1 = nil
        store.dispatch(SetValueAction(5))
        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(subscriber2?.receivedStates.last?.testValue, 5)

        subscriber2 = nil
        store.dispatch(SetValueAction(8))
        XCTAssertEqual(store.subscriptions.count, 0)
    }

    /**
     it replaces the subscription of an existing subscriber with the new one.
     */
    func testDuplicateSubscription() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        // Initial subscription.
        store.subscribe(subscriber)
        // Subsequent subscription that skips repeated updates.
        store.subscribe(subscriber) { $0.skipRepeats { $0.testValue == $1.testValue } }

        // One initial state update for every subscription.
        XCTAssertEqual(subscriber.receivedStates.count, 2)

        store.dispatch(SetValueAction(3))
        store.dispatch(SetValueAction(3))
        store.dispatch(SetValueAction(3))
        store.dispatch(SetValueAction(3))

        // Only a single further state update, since latest subscription skips repeated values.
        XCTAssertEqual(subscriber.receivedStates.count, 3)
    }
    /**
     it dispatches initial value upon subscription
     */
    func testDispatchInitialValue() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(3))

        XCTAssertEqual(subscriber.receivedStates.last?.testValue, 3)
    }

    /**
     it allows dispatching from within an observer
     */
    func testAllowDispatchWithinObserver() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = DispatchingSubscriber(store: store)

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(2))

        XCTAssertEqual(store.state.testValue, 5)
    }

    /**
     it does not dispatch value after subscriber unsubscribes
     */
    func testDontDispatchToUnsubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.dispatch(SetValueAction(5))
        store.subscribe(subscriber)
        store.dispatch(SetValueAction(10))

        store.unsubscribe(subscriber)
        // Following value is missed due to not being subscribed:
        store.dispatch(SetValueAction(15))
        store.dispatch(SetValueAction(25))

        store.subscribe(subscriber)

        store.dispatch(SetValueAction(20))

        XCTAssertEqual(subscriber.receivedStates.count, 4)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 4].testValue, 5)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 3].testValue, 10)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 2].testValue, 25)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 1].testValue, 20)
    }

    /**
     it ignores identical subscribers
     */
    func testIgnoreIdenticalSubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.subscribe(subscriber)
        store.subscribe(subscriber)

        XCTAssertEqual(store.subscriptions.count, 1)
    }

    /**
     it ignores identical subscribers that provide substate selectors
     */
    func testIgnoreIdenticalSubstateSubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.subscribe(subscriber) { $0 }
        store.subscribe(subscriber) { $0 }

        XCTAssertEqual(store.subscriptions.count, 1)
    }
}
