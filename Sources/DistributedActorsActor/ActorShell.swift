//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import Dispatch
import Logging
import CSwiftDistributedActorsMailbox

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor internals

/// The shell is responsible for interpreting messages using the current behavior.
/// In simplified terms, it can be thought of as "the actual actor," as it is the most central piece where
/// all actor interactions with messages, user code, and the mailbox itself happen.
///
/// The shell is mutable, and full of dangerous and carefully threaded/ordered code, be extra cautious.
@usableFromInline
internal final class ActorShell<Message>: ActorContext<Message>, AbstractActor {

    // The phrase that "actor change their behavior" can be understood quite literally;
    // On each message interpretation the actor may return a new behavior that will be handling the next message.
    @usableFromInline
    var behavior: Behavior<Message>

    let _parent: AddressableActorRef

    let _path: UniqueActorPath

    let _props: Props

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Basic ActorContext capabilities

    private let _dispatcher: MessageDispatcher

    @usableFromInline
    var _system: ActorSystem
    override public var system: ActorSystem {
        return self._system
    }

    /// Guaranteed to be set during ActorRef creation
    /// Must never be exposed to users, rather expose the `ActorRef<Message>` by calling `myself`.
    @usableFromInline
    lazy var _myCell: ActorCell<Message> =
        ActorCell<Message>(
            path: self._path,
            actor: self,
            mailbox: Mailbox(shell: self, capacity: self._props.mailbox.capacity)
        )

    @usableFromInline
    var _myselfReceivesSystemMessages: ReceivesSystemMessages {
        return self.myself
    }
    @usableFromInline
    var asAddressable: AddressableActorRef {
        return self.myself.asAddressable()
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Timers

    override public var timers: Timers<Message> {
        return self._timers
    }

    lazy var _timers: Timers<Message> = Timers(context: self)

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Fault handling infrastructure

    // We always have a supervisor in place, even if it is just the ".stop" one.
    @usableFromInline internal let supervisor: Supervisor<Message>
    // TODO: we can likely optimize not having to call "through" supervisor if we are .stopped anyway

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Defer

    @usableFromInline
    internal var deferred = DefersContainer()

    override public func `defer`(until: DeferUntilWhen,
                                 file: String = #file, line: UInt = #line,
                                 _ closure: @escaping () -> Void) {
        do {
            let deferred = ActorDeferredClosure(until: until, closure, file: file, line: line)
            try self.deferred.push(deferred)
        } catch {
            // FIXME: Only reason this fails silently and not fatalErrors is since it would easily get into crash looping infinitely...
            self.log.error("Attempted to invoke context.defer nested in another context.defer execution. This is currently not supported. \(error)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch infrastructure

    // Implementation of DeathWatch
    @usableFromInline internal var _deathWatch: DeathWatch<Message>?
    @usableFromInline internal var deathWatch: DeathWatch<Message> {
        get {
            guard let d = self._deathWatch else {
                fatalError("BUG! Tried to access deathWatch on \(self.path) and it was nil!!!! Maybe a message was handled after tombstone?")
            }
            return d
        }
        set {
            self._deathWatch = newValue
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ActorShell implementation

    internal init(system: ActorSystem, parent: AddressableActorRef,
                  behavior: Behavior<Message>, path: UniqueActorPath,
                  props: Props, dispatcher: MessageDispatcher) {
        self._system = system
        self._parent = parent

        self.behavior = behavior
        self._path = path
        self._props = props
        self._dispatcher = dispatcher

        self.supervisor = Supervision.supervisorFor(system, initialBehavior: behavior, props: props.supervision)

        if let failureDetectorRef = system._cluster?._failureDetectorRef {
            self._deathWatch = DeathWatch(failureDetectorRef: failureDetectorRef)
        } else {
            // FIXME; we could see if `myself` is the right one actually... rather than dead letters; if we know the FIRST actor ever is the failure detector one?
            self._deathWatch = DeathWatch(failureDetectorRef: system.deadLetters.adapted())
        }

        #if SACT_TESTS_LEAKS
        // We deliberately only count user actors here, because the number of
        // system actors may change over time and they are also not relevant for
        // this type of test.
        if path.segments.first?.value == "user" {
            _ = system.userCellInitCounter.add(1)
        }
        #endif
    }

    deinit {
        traceLog_Cell("deinit cell \(_path)")
        #if SACT_TESTS_LEAKS
        if self.path.segments.first?.value == "user" {
            _ = system.userCellInitCounter.sub(1)
        }
        #endif
    }

    /// INTERNAL API: MUST be called immediately after constructing the cell and ref,
    /// as the actor needs to access its ref from its context during setup or other behavior reductions
    internal func set(ref: ActorCell<Message>) {
        self._myCell = ref // TODO: atomic?
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Children

    private let _childrenLock = ReadWriteLock()
    // All access must be protected with `_childrenLock`, or via `children` helper
    internal var _children: Children = Children()
    override public var children: Children {
        set {
            self._childrenLock.lockWrite()
            defer { self._childrenLock.unlock() }
            self._children = newValue
        }
        get {
            self._childrenLock.lockRead()
            defer { self._childrenLock.unlock() }
            return self._children
        }
    }

    func dropMessage(_ message: Message) {
        // TODO implement support for logging dropped messages; those are different than deadLetters
        pprint("[dropped] Message [\(message)]:\(type(of: message)) was not delivered.")
        // system.deadLetters.tell(Dropped(message)) // TODO metadata
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Conforming to ActorContext

    /// Returns this actors "self" actor reference, which can be freely shared across
    /// threads, actors, and even nodes (if clustering is used).
    ///
    /// Warning: Do not use after actor has terminated (!)
    override public var myself: ActorRef<Message> {
        return .init(.cell(self._myCell))
    }

    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    override public var path: UniqueActorPath {
        return self._path
    }
    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    override public var name: String {
        return self.path.name
    }

    // access only from within actor
    private lazy var _log = ActorLogger.make(context: self)
    override public var log: Logger {
        get {
            return self._log
        }
        set {
            self._log = newValue
        }
    }

    override public var dispatcher: MessageDispatcher {
        return self._dispatcher
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Interpreting messages

    /// Interprets the incoming message using the current `Behavior` and swaps it with the
    /// next behavior (as returned by user code, which the message was applied to).
    ///
    /// Warning: Mutates the cell's behavior.
    /// Returns: `true` if the actor remains alive, and `false` if it now is becoming `.stopped`
    @inlinable
    func interpretMessage(message: Message) throws -> SActActorRunResult {
        #if SACT_TRACE_ACTOR_SHELL
        pprint("Interpret: [\(message)]:\(type(of: message)) with: \(behavior)")
        #endif

        let next: Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, message: message)

        #if SACT_TRACE_ACTOR_SHELL
        log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)")
        #endif // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

        try self.deferred.invokeAllAfterReceived()

        if next.isChanging {
            try self.becomeNext(behavior: next)
        }

        if !self.behavior.isStillAlive {
            self.children.stopAll()
        }

        return self.runState
    }

    @inlinable
    var runState: SActActorRunResult {
        if self.continueRunning {
            return .continueRunning
        } else if self.isSuspended {
            return .shouldSuspend
        } else {
            return .shouldStop
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling system messages

    /// Process single system message and return if processing of further shall continue.
    /// If not, then they will be drained to deadLetters – as it means that the actor is terminating!
    ///
    /// Throws:
    ///   - user behavior thrown exceptions
    ///   - or `DeathPactError` when a watched actor terminated and the termination signal was not handled; See "death watch" for details.
    /// Fails:
    ///   - can potentially fail, which is handled by [FaultHandling] and terminates an actor run immediately.
    func interpretSystemMessage(message: SystemMessage) throws -> SActActorRunResult {
        traceLog_Cell("Interpret system message: \(message)")

        switch message {
        case .start:
            try self.interpretStart()

        // death watch
        case let .watch(_, watcher):
            self.interpretSystemWatch(watcher: watcher)
        case let .unwatch(_, watcher):
            self.interpretSystemUnwatch(watcher: watcher)

        case let .terminated(ref, existenceConfirmed, _):
            let terminated = Signals.Terminated(path: ref.path, existenceConfirmed: existenceConfirmed)
            try self.interpretTerminatedSignal(who: ref, terminated: terminated)
        case let .childTerminated(ref):
            let terminated = Signals.ChildTerminated(path: ref.path, error: nil) // TODO what about the errors
            try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)
        case let .addressTerminated(remoteAddress):
            self.interpretAddressTerminated(remoteAddress)

        case .stop:
            try self.interpretStop()

        case .resume(let result):
            switch self.behavior.underlying {
            case let .suspended(previousBehavior, handler):
                let nextBehavior = try self.supervisor.interpretSupervised(target: previousBehavior, context: self) {
                    return try handler(result)
                }
                try self.becomeNext(behavior: previousBehavior.canonicalize(self, next: nextBehavior))
            default:
                self.log.error("Received .resume message while being in non-suspended state")

            }

        case .tombstone:
            return self.finishTerminating()
        }

        return self.runState
    }

    func interpretClosure(_ closure: @escaping () throws -> Void) throws -> SActActorRunResult {
        let next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, closure: closure)

        traceLog_Cell("Applied closure, becoming: \(next)")

        try self.becomeNext(behavior: next)

        if !self.behavior.isStillAlive {
            self.children.stopAll()
        }

        return self.runState
    }

    @inlinable
    internal var continueRunning: Bool {
        switch self.behavior.underlying {
        case .suspended: return false
        case .stopped:   return self.children.nonEmpty
        default:         return true
        }
    }

    @usableFromInline
    internal var isSuspended: Bool {
        return self.behavior.isSuspended
    }

    /// Fails the actor using the passed in error.
    ///
    /// May ONLY be invoked by the Mailbox.
    ///
    /// Special handling is applied to `DeathPactError` since if that error is passed in here, we know that `.terminated`
    /// was not handled and we have to adhere to the DeathPact contract by stopping this actor as well.
    ///
    /// We only FORCE the sending of a tombstone if we know we have parked the thread because an actual failure happened,
    /// thus this run *will never complete* and we have to make sure that we run the cleanup that the tombstone causes.
    /// This means that while the current thread is parked forever, we will enter the mailbox with another last run (!), to process the cleanups.
    internal func fail(_ error: Error) {
        self._myCell.mailbox.setFailed()
        self.behavior = self.behavior.makeFailed(cause: .error(error))
        // TODO: we could handle here "wait for children to terminate"

        // we only finishTerminating() here and not right away in message handling in order to give the Mailbox
        // a chance to react to the problem as well; I.e. 1) we throw 2) mailbox sets terminating 3) we get fail() 4) we REALLY terminate
        switch error {
        case let DeathPactError.unhandledDeathPact(_, _, message):
            log.error("\(message)") // TODO configurable logging? in props?

        default:
            log.error("Actor threw error, reason: [\(error)]:\(type(of: error)). Terminating.") // TODO configurable logging? in props?
        }
    }

    /// Similar to `fail` however assumes that the current mailbox run will never complete, which can happen when we crashed,
    /// and invoke this function from a signal handler.
    public func reportCrashFail(cause: MessageProcessingFailure) {

        // if supervision or configurations or failure domain dictates something else will happen, explain it to the user here
        let crashHandlingExplanation = "Terminating actor, process and thread remain alive."

        log.error("Actor crashing, reason: [\(cause)]:\(type(of: cause)). \(crashHandlingExplanation)")

        self.behavior = self.behavior.makeFailed(cause: .fault(cause))
    }

    /// Used by supervision, from failure recovery.
    /// In such case the cell must be restarted while the mailbox remain in-tact.
    ///
    /// - Warning: This call MAY throw if user code would throw in reaction to interpreting `PreRestart`;
    ///            If this happens the actor MUST be terminated immediately as we suspect things went very bad™ somehow.
    @inlinable public func _restartPrepare() throws {
        self.children.stopAll(includeAdapters: false)
        self.timers.cancelAll() // TODO cancel all except the restart timer

        // since we are restarting that means that we have failed
        try self.deferred.invokeAllAfterFailing()

        /// Yes, we ignore the behavior returned by pre-restart on purpose, the supervisor decided what we should `become`,
        /// and we can not change this decision; at least not in the current scheme (which is simple and good enough for most cases).
        _ = try self.behavior.interpretSignal(context: self, signal: Signals.PreRestart())

        // NOT interpreting Start yet, as it may have to be done after a delay
    }

    /// Used by supervision.
    /// MUST be preceded by an invocation of `restartPrepare`.
    /// The two steps MAY be performed in different point in time; reason being: backoff restarts,
    /// which need to suspend the actor, and NOT start it just yet, until the system message awakens it again.
    @inlinable public func _restartComplete(with behavior: Behavior<Message>) throws -> Behavior<Message> {
        try behavior.validateAsInitial()

        self.behavior = behavior
        try self.interpretStart()
        return self.behavior
    }

    /// Encapsulates logic that has to always be triggered on a state transition to specific behaviors
    /// Always invoke `becomeNext` rather than assigning to `self.behavior` manually.
    ///
    /// Returns: `true` if next behavior is .stopped and appropriate actions will be taken
    @inlinable
    internal func becomeNext(behavior next: Behavior<Message>) throws {
        // TODO: handling "unhandled" would be good here... though I think type wise this won't fly, since we care about signal too
        self.behavior = try self.behavior.canonicalize(self, next: next)
    }

    @inlinable
    internal func interpretStart() throws {
        // start means we need to evaluate all `setup` blocks, since they need to be triggered eagerly

        traceLog_Cell("START with behavior: \(self.behavior)")
        let started = try self.supervisor.startSupervised(target: self.behavior, context: self)
        try self.becomeNext(behavior: started)
    }

    // MARK: Lifecycle and DeathWatch TODO move death watch things all into an extension

    // TODO: this is also part of lifecycle / supervision... maybe should be in an extension for those

    /// This is the final method an ActorCell ever runs.
    ///
    /// It notifies any remaining watchers about its termination, releases any remaining resources,
    /// and clears its behavior, allowing state kept inside it to be released as well.
    ///
    /// Once this method returns the cell becomes "terminated", an empty shell, and may never be run again.
    /// This is coordinated with its mailbox, which by then becomes closed, and shall no more accept any messages, not even system ones.
    ///
    /// Any remaining system messages are to be drained to deadLetters by the mailbox in its current run.
    private func finishTerminating() -> SActActorRunResult {
        self._myCell.mailbox.setClosed()

        let myPath: UniqueActorPath? = self._myCell.path
        traceLog_Cell("FINISH TERMINATING \(self)")

        // TODO: stop all children? depends which style we'll end up with...
        // TODO: the thing is, I think we can express the entire "wait for children to stop" as a behavior, and no need to make it special implementation in the cell

        self.timers.cancelAll()

        // notifying parent and other watchers has no ordering guarantees with regards to reception,
        // however let's first notify the parent and then all other watchers (even if parent did watch this child
        // we do not need to send it another terminated message, the terminatedChild is enough).
        //
        // note that even though the parent can (and often does) `watch(child)`, we filter it out from
        // our `watchedBy` set, since otherwise we would have to filter it out when sending the terminated back.
        // correctness is ensured though, since the parent always receives the `ChildTerminated`.
        self.notifyParentWeDied()
        self.notifyWatchersWeDied()

        self.invokePendingDeferredClosuresWhileTerminating()

        do {
            _ = try self.behavior.interpretSignal(context: self, signal: Signals.PostStop())
        } catch {
            // TODO: should probably .escalate instead;
            self.log.error("Exception in postStop. Supervision will NOT be applied. Error \(error)")
        }

        // TODO validate all the nulling out; can we null out the cell itself?
        self._deathWatch = nil
        self.messageAdapters = [:]

        // become stopped, if not already
        switch self.behavior.underlying {
        case .stopped: () // already marked as stopped
        default: self.behavior = .stopped
        }

        traceLog_Cell("CLOSED DEAD: \(String(describing: myPath)) has completely terminated, and will never act again.")

        // It shall act, ah, nevermore!
        return .closed
    }

    // Implementation note: bridge method so Mailbox can call this when needed
    func notifyWatchersWeDied() {
        traceLog_DeathWatch("NOTIFY WATCHERS WE ARE DEAD self: \(self.path)")
        self.deathWatch.notifyWatchersWeDied(myself: self.myself)
    }
    func notifyParentWeDied() {
        let parent: AddressableActorRef = self._parent
        traceLog_DeathWatch("NOTIFY PARENT WE ARE DEAD, myself: [\(self.path)], parent [\(parent.path)]")
        parent.sendSystemMessage(.childTerminated(ref: myself.asAddressable()))
    }

    func invokePendingDeferredClosuresWhileTerminating() {
        do {
            switch self.behavior.underlying {
            case .stopped(_, let reason):
                switch reason {
                case .failure:
                    try self.deferred.invokeAllAfterFailing()
                case .stopMyself, .stopByParent:
                    try self.deferred.invokeAllAfterStop()
                }
            case .failed:
                try self.deferred.invokeAllAfterFailing()
            default:
                fatalError("Potential bug. Should only be invoked on .stopped / .failed")
            }
        } catch {
            self.log.error("Invoking context.deferred closures threw: \(error), remaining closures will NOT be invoked. Proceeding with termination.")
        }
    }

    // MARK: Spawn implementations

    public override func spawn<M>(_ behavior: Behavior<M>, name: String, props: Props) throws -> ActorRef<M> {
        return try self._spawn(behavior, name: name, props: props)
    }

    public override func spawnAnonymous<M>(_ behavior: Behavior<M>, props: Props = Props()) throws -> ActorRef<M> {
        return try self._spawn(behavior, name: self.system.anonymousNames.nextName(), props: props)
    }

    public override func spawnWatched<M>(_ behavior: Behavior<M>, name: String, props: Props = Props()) throws -> ActorRef<M> {
        return self.watch(try self.spawn(behavior, name: name, props: props))
    }

    public override func spawnWatchedAnonymous<M>(_ behavior: Behavior<M>, props: Props) throws -> ActorRef<M> {
        return self.watch(try self.spawnAnonymous(behavior, props: props))
    }

    public override func stop<M>(child ref: ActorRef<M>) throws {
        return try self.internal_stop(child: ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch API

    override public func watch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        self.deathWatch.watch(watchee: watchee.asAddressable(), myself: self.myself, parent: self._parent)
        return watchee
    }

    override internal func watch(_ watchee: AddressableActorRef) {
        self.deathWatch.watch(watchee: watchee, myself: self.myself, parent: self._parent)
    }

    override public func unwatch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        self.deathWatch.unwatch(watchee: watchee.asAddressable(), myself: self.myself)
        return watchee
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Message Adapters API

    private var messageAdapters: [FullyQualifiedTypeName: AddressableActorRef] = [:]

    override func messageAdapter<From>(for type: From.Type, with adapter: @escaping (From) -> Message) -> ActorRef<From> {
        let name = self.system.anonymousNames.nextName()
        do {
            let adaptedPath = try self.path.makeChildPath(name: name, uid: ActorUID.random())
            let ref = ActorRefAdapter(self.myself, path: adaptedPath, converter: adapter)

            self._children.insert(ref) // TODO separate adapters collection?
            return .init(.adapter(ref))
        } catch {
            fatalError("""
                       Failed while creating message adapter. This should never happen, since message adapters have unique names 
                       generated for them using sequential names. Maybe `ActorContext.messageAdapter` was accessed concurrently (which is unsafe!)? 
                       Error: \(error)
                       """)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal system message / signal handling functions

extension ActorShell {
    @inlinable internal func interpretSystemWatch(watcher: AddressableActorRef) {
        if self.behavior.isStillAlive {
            // TODO: make DeathWatch methods available via extension
            self.deathWatch.becomeWatchedBy(watcher: watcher, myself: self.myself)
        } else {
            // so we are in the middle of terminating already anyway
            watcher.sendSystemMessage(.terminated(ref: self.asAddressable, existenceConfirmed: true))
        }
    }

    @inlinable internal func interpretSystemUnwatch(watcher: AddressableActorRef) {
        self.deathWatch.removeWatchedBy(watcher: watcher, myself: self.myself) // TODO: make DeathWatch methods available via extension
    }

    /// Interpret incoming .terminated system message
    ///
    /// Mutates actor cell behavior.
    /// May cause actor to terminate upon error or returning .stopped etc from `.signalHandling` user code.
    @inlinable internal func interpretTerminatedSignal(who deadRef: AddressableActorRef, terminated: Signals.Terminated) throws {
        #if SACT_TRACE_ACTOR_SHELL
        log.info("Received terminated: \(deadRef)")
        #endif

        guard self.deathWatch.receiveTerminated(terminated) else {
            // it is not an actor we currently watch, thus we should not take actions nor deliver the signal to the user
            log.warning("Actor not known, but [\(terminated)] received for it. Ignoring.")
            return
        }

        let next: Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)

        switch next.underlying {
        case .unhandled:
            throw DeathPactError.unhandledDeathPact(terminated: deadRef, myself: self.myself.asAddressable(),
                message: "Death Pact error: [\(self.path)] has not handled [Terminated] signal received from watched [\(deadRef)] actor. " +
                    "Handle the `.terminated` signal in `.receiveSignal()` in order react to this situation differently than termination.")
        default:
            try becomeNext(behavior: next) // FIXME make sure we don't drop the behavior...?
        }
    }

    /// Interpret incoming .addressTerminated system message.
    ///
    /// Results in signaling `Terminated` for all of the locally watched actors on the (now terminated) node.
    /// This action is performed concurrently by all actors who have watched remote actors on given node,
    /// and no ordering guarantees are made about which actors will get the Terminated signals first.
    @inlinable internal func interpretAddressTerminated(_ terminatedAddress: UniqueNodeAddress) {
        #if SACT_TRACE_ACTOR_SHELL
        log.info("Received address terminated: \(deadRef)")
        #endif

        self.deathWatch.receiveAddressTerminated(terminatedAddress, myself: self.asAddressable)
    }

    @inlinable internal func interpretStop() throws {
        children.stopAll()
        try self.becomeNext(behavior: .stopped(reason: .stopByParent))
    }

    @inlinable internal func interpretChildTerminatedSignal(who terminatedRef: AddressableActorRef, terminated: Signals.ChildTerminated) throws {
        #if SACT_TRACE_ACTOR_SHELL
        log.info("Received \(terminated)")
        #endif

        // we always first need to remove the now terminated child from our children
        _ = self.children.removeChild(identifiedBy: terminatedRef.path)
        // Implementation notes:
        // Normally this does not happen, however it MAY occur when the parent actor (self)
        // immediately performed a `stop()` on the child, and thus removes it from its
        // children container immediately; The following termination notification would therefore
        // reach the parent in which the child was already removed.

        // next we may apply normal deathWatch logic if the child was being watched
        if self.deathWatch.isWatching(path: terminatedRef.path) {
            return try self.interpretTerminatedSignal(who: terminatedRef, terminated: terminated)
        } else {
            // otherwise we deliver the message, however we do not terminate ourselves if it remains unhandled


            let next: Behavior<Message>
            if case .signalHandling = self.behavior.underlying {
                // TODO we always want to call "through" the supervisor, make it more obvious that that should be the case internal API wise?
                next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)
            } else {
                // no signal handling installed is semantically equivalent to unhandled
                // log.debug("No .signalHandling installed, yet \(message) arrived; Assuming .unhandled")
                next = Behavior<Message>.unhandled
            }

            try becomeNext(behavior: next)
        }
    }
}

extension ActorShell: CustomStringConvertible {
    public var description: String {
        let path = self._myCell.path.description
        return "\(type(of: self))(\(path))"
    }
}

/// The purpose of this cell is to allow storing cells of different types in a collection, i.e. Children
internal protocol AbstractActor: _ActorTreeTraversable  {

    var _myselfReceivesSystemMessages: ReceivesSystemMessages { get }
    var children: Children { get set } // lock-protected
    var asAddressable: AddressableActorRef { get }
}

extension AbstractActor {

    @inlinable
    var receivesSystemMessages: ReceivesSystemMessages {
        return self._myselfReceivesSystemMessages
    }

    @inlinable
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        var c = context.deeper
        switch visit(context, self.asAddressable) {
        case .continue:
            let res = self.children._traverse(context: c, visit)
            return res
        case .accumulateSingle(let t):
            c.accumulated.append(t)
            return self.children._traverse(context: c, visit)
        case .accumulateMany(let ts):
            c.accumulated.append(contentsOf: ts)
            return self.children._traverse(context: c, visit)
        case .abort(let err):
            return .failed(err)
        }
    }

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        let myself: ReceivesSystemMessages = self._myselfReceivesSystemMessages

        guard context.selectorSegments.first != nil else {
            // no remaining selectors == we are the "selected" ref, apply uid check
            if myself.path.uid == context.selectorUID {
                switch myself {
                case let myself as ActorRef<Message>:
                    return myself
                default:
                    return context.deadRef
                }
            } else {
                // the selection was indeed for this path, however we are a different incarnation (or different actor)
                return context.deadRef
            }
        }

        return self.children._resolve(context: context)
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        let myself: ReceivesSystemMessages = self._myselfReceivesSystemMessages

        guard context.selectorSegments.first != nil else {
            // no remaining selectors == we are the "selected" ref, apply uid check
            if myself.path.uid == context.selectorUID {
                return self.asAddressable
            } else {
                // the selection was indeed for this path, however we are a different incarnation (or different actor)
                return context.deadRef.asAddressable()
            }
        }

        return self.children._resolveUntyped(context: context)
    }
}

internal extension ActorContext {
    /// INTERNAL API: UNSAFE, DO NOT TOUCH.
    @usableFromInline
    var _downcastUnsafe: ActorShell<Message> {
        switch self {
        case let shell as ActorShell<Message>: return shell
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to ActorCell. This is a bug, please report this on the issue tracker.")
        }
    }
}