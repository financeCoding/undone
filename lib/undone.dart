
/// A library for undo and redo.
library undone;

import 'dart:async';

/// A function to do an operation on an [arg] and return a result.
typedef R Do<A, R>(A arg);

/// A function to do an async operation on an [arg] and complete a result.
typedef Future<R> DoAsync<A, R>(A arg);

/// A function to undo an operation on an [arg] given the prior [result].
typedef void Undo<A, R>(A arg, R result);

/// A function to undo an async operation on an [arg] given the prior [result].
typedef Future UndoAsync<A, R>(A arg, R result);

Schedule _schedule;
/// The isolate's top-level [Schedule].
Schedule get schedule {
  if (_schedule == null) _schedule = new Schedule();
  return _schedule;
}

Transaction _transaction;
/// Build and compute a [Transaction] using the top-level [schedule].
/// Returns a Future for the transaction's completion.
Future transact(void build()) {
  assert(_transaction == null);  
  var txn = new Transaction();
  _transaction = txn;
  try {
    build();
  } catch(e) {
    // Clear the deferred future for each action that was added in the build.
    _transaction._arg.forEach((action) => action._deferred = null);
    return new Future.immediateError(e);
  } finally {
    _transaction = null;
  }
  return txn();
}

/// Undo the next action to be undone in the top-level [schedule], if any.
/// Completes _true_ if an action was undone or else completes _false_.
Future<bool> undo() => schedule.undo();

/// Redo the next action to be redone in the top-level [schedule], if any.
/// Completes _true_ if an action was redone or else completes _false_.
Future<bool> redo() => schedule.redo();

/// An action that can be done and undone.
///
/// Actions are comprised of a pair of functions: one to [Do] the action and
/// another to [Undo] the action.  The action object is itself a [Function] that 
/// can be [call]ed to schedule it to be done on the top-level [schedule] or
/// to add it to a [Transaction] if called within the scope of [transact].
/// Actions may also be constructed with a pair of [DoAsync] and [UndoAsync]
/// functions using the [new Action.async] constructor.  All actions are done
/// and undone asynchronously, regardless of the functions themselves.  Actions
/// may be optionally typed by their argument and result objects, [A] and [R].
/// The action type may be extended to define custom actions although this may
/// often not be necessary; constructing an action with the functions to do and
/// undo the desired operation is often the simplest and best approach.
class Action<A, R> {
  final A _arg;
  R _result; // The result of the most recent call().
  final DoAsync _do;
  final UndoAsync _undo;
  Completer _deferred;
  
  /// Constructs a new action with the given [arg]uments, [Do] function, and 
  /// [Undo] function.  The given synchronous functions are automatically 
  /// wrapped in futures prior to being called on a schedule.
  Action(A arg, Do d, Undo u) : this._(arg,
    d == null ? d : (a) => new Future.of(() => d(a)), 
    u == null ? u : (a, r) => new Future.of(() => u(a, r)));
  
  /// Constructs a new action with the given [arg]uments, [DoAsync] function, 
  /// and [UndoAsync] function.
  Action.async(A arg, DoAsync d, UndoAsync u) : this._(arg, d, u);
  
  Action._(this._arg, this._do, this._undo) {
    if (_do == null) throw new ArgumentError('Do function must be !null.');
    if (_undo == null) throw new ArgumentError('Undo function must be !null.');
  }
  
  /// Schedules this action to be called on the top-level [schedule].  If this
  /// action is called within the scope of a top-level [transact] method it will
  /// instead be added to that transaction.  Completes with the result of the
  /// action in both cases.
  Future<R> call() {    
    if (_transaction != null) {
      _transaction.add(this);
      return this._defer();
    }
    return schedule(this);
  }
  
  Future<R> _defer() {    
    // The action may only give out 1 deferred future at a time.
    assert(_deferred == null);
    _deferred = new Completer<R>();
    return _deferred.future;
  }
  
  Future<R> _execute() {
    if (_deferred == null) return _do(_arg);
    else {
      // If the action was deferred, we complete the future we handed out prior.
      return _do(_arg)
        .then((result) => _deferred.complete(result))
        .catchError(
            (e) { throw new StateError('Error wrongfully caught.'); }, 
            test: (e) {
              // Complete the error to the deferred future, but allow the error
              // to propogate back to the schedule also so that it can 
              // transition to its error state.
              _deferred.completeError(e);
              return false;
            })
        .whenComplete(() => _deferred = null);
    }
  }
  
  Future _unexecute() => _undo(_arg, _result);  
}

/// An error encountered during a transaction.
class TransactionError {
  /// The caught object that caused the transaction to err.
  final cause;  
  var _rollbackError;
  /// An error encountered during transaction rollback; may be null if none.
  get rollbackError => _rollbackError;
  /// Constructs a new transaction error with the given cause.
  TransactionError(this.cause);
}

/// A sequence of actions that are done and undone together as if one action.
///
/// A transaction is itself an action that may be [call]ed on a schedule.
/// When a transaction is scheduled to be done or undone it will do or undo
/// all of its actions in sequence.  Any errors that occur when doing one of
/// its actions will cause the transaction to attempt to undo all of its actions
/// that were done prior to the error; this is known as rollback.  These errors
/// will be wrapped in a [TransactionError] and completed to the caller.
class Transaction extends Action {
  
  static Future _do_(List<Action> actions) {
    var completer = new Completer<List>();            
    var current;
    // Try to do all the actions in order.
    Future.forEach(actions, (action) {
      // Keep track of the current action in case an error happens.
      current = action;
      return action._execute();
    }).then((_) => completer.complete())
      .catchError((e) {
        final err = new TransactionError(e);
        final reverse = actions.reversed.skipWhile((e) => e == current);
        // Try to undo from the point of failure back to the start.
        Future.forEach(reverse, (action) => action._unexecute())
          // We complete with error even if rollback succeeds.
          .then((_) => completer.completeError(err))
          .catchError((e) { 
            // Double trouble, give both errors to the caller.
            err._rollbackError = e;
            completer.completeError(err);
          });
      });
    return completer.future;
  }
  
  static Future _undo_(List<Action> actions, _) => 
      Future.forEach(actions.reversed, (action) => action._unexecute());
  
  /// Constructs a new empty transaction.
  Transaction() : super._(new List<Action>(), _do_, _undo_);
  
  /// Adds the given [action] to this transaction.
  void add(Action action) => _arg.add(action);
}

/// An asynchronous schedule of actions.
///
/// A schedule is a [Function] that can be [call]ed with [Action]s.  The order 
/// of such calls is preserved in a history to allow for [undo] and [redo].  An 
/// action may be scheduled at any time; if the schedule is not [busy] then it 
/// will be called immediately, otherwise it will be queued to be called as soon 
/// as possible.  Methods to change the history such as [undo] and [redo] can 
/// _not_ be invoked when the schedule is [busy].  This ensures that all queued 
/// actions are called and the schedule reaches an idle state before the history 
/// may be modified.  Each schedule is a state machine, and its [states] are 
/// observable as a stream; this provides a convenient means to connect a user 
/// interface to the history control methods.
class Schedule {
  /// A schedule is idle (not busy).
  static const int STATE_IDLE = 0;
  /// A schedule is busy executing a new action.
  static const int STATE_CALL = 1;
  /// A schedule is busy flushing pending actions.
  static const int STATE_FLUSH = 2;
  /// A schedule is busy performing a redo operation.
  static const int STATE_REDO = 4;
  /// A schedule is busy performing an undo operation.
  static const int STATE_UNDO = 8;
  /// A schedule is busy performing a to operation.
  static const int STATE_TO = 16;
  /// A schedule has an error.
  static const int STATE_ERROR = 32;
  
  final _actions = new List<Action>();
  // Actions that are called while this schedule is busy are pending to be done.
  final _pending = new List<Action>();
  int _nextUndo = -1;
  int _currState = STATE_IDLE;
  var _err;
  
  /// Whether or not this schedule is busy performing another action.
  /// This is always _true_ when called from any continuations that are
  /// chained to Futures returned by methods on this schedule.
  /// This is also _true_ if this schedule has an [error].
  bool get busy => _state != STATE_IDLE;
  
  /// Whether or not this schedule can be [clear]ed at the present time.
  bool get canClear => !busy || hasError;
  
  bool get _canRedo => _nextUndo < _actions.length - 1;
  /// Whether or not the [redo] method may be called at the present time.
  bool get canRedo => !busy && _canRedo;
  
  bool get _canUndo => _nextUndo >= 0;
  /// Whether or not the [undo] method may be called at the present time.
  bool get canUndo => !busy && _canUndo;
  
  /// Whether or not this schedule has an [error].
  bool get hasError => _state == STATE_ERROR;
    
  /// The current error, if [hasError] is _true_.  This schedule will remain
  /// [busy] for as long as this schedule [hasError].  You may [clear] this
  /// schedule after dealing with the error condition in order to use it again.
  get error => _err;
  set _error(e) {
    _err = e;
    _state = STATE_ERROR;
  }
  
  // The current state of this schedule.
  int get _state => _currState;
  set _state(int nextState) {
    if (nextState != _currState) {
      _currState = nextState;
      _states.add(_currState);
    }
  }
  
  final _states = new StreamController<int>();
  /// An observable stream of this schedule's state transitions.
  Stream<int> get states => _states.stream;
      
  /// Schedule the given [action] to be called.  If this schedule is not [busy], 
  /// the action will be called immediately.  Else, the action will be deferred 
  /// in order behind any other pending actions to be called once this schedule 
  /// reaches an idle state.
  Future call(Action action) {
    if (hasError) {
      _error = new StateError('Cannot call if Schedule.hasError.');
      return new Future.immediateError(error); 
    }
    if (_actions.contains(action) || _pending.contains(action)) {
      _error = new StateError('Cannot call $action >1 time on same schedule.');
      return new Future.immediateError(error);
    }
    if (busy) {
      _pending.add(action);
      return action._defer();
    }
    _state = STATE_CALL;
    return _do(action);
  }
  
  /// Clears this schedule if [canClear] is _true_ at this time and returns
  /// _true_ if the operation succeeds or _false_ if it does not succeed.
  bool clear() {
    if (!canClear) return false;
    _actions.clear();
    _pending.clear();
    _nextUndo = -1;
    _state = STATE_IDLE;
    _err = null;
    return true;
  }
  
  Future _do(action) {    
    var completer = new Completer();
    action._execute()
      .then((result) {
        // Truncate the end of list (redo actions) when adding a new action.
        _actions.removeRange(_nextUndo + 1, _actions.length - 1 - _nextUndo);
        action._result = result;
        _actions.add(action);
        _nextUndo++;
        // Complete the result before we flush pending and transition to idle.
        // This ensures 2 things:
        //    1) The continuations of the action see the state as the result of 
        //       this action and _not_ the state of further pending actions.
        //    2) The order of pending actions is preserved as the user is not
        //       able to undo or redo (busy == true) in continuations.
        completer.complete(result);
        // Flush any pending actions that were deferred as we did this action.        
        _flush();
      })
      .catchError((e) {
        _error = e;
        completer.completeError(e);
      });    
    return completer.future;    
  }
  
  Future _flush() {
    // Nothing pending means no work to do but we still must return a future.
    if (!_pending.isEmpty) _state = STATE_FLUSH;
    // Copy _pending actions to a new list to iterate because new actions 
    // may be added to _pending while we are iterating.
    final _flushing = _pending.toList();
    _pending.clear();
    return Future
      .forEach(_flushing, (action) => _do(action)) 
      .then((_) => _state = STATE_IDLE)
      // The action will complete the error to its continuations, but we will 
      // also receive it here in order to transition to the error state.
      .catchError((e) => _error = e);
  }
  
  /// Undo or redo all ordered actions in this schedule until the given [action] 
  /// is done.  The state of the schedule after this operation is equal to the 
  /// state upon completion of the given action. Completes _false_ if any undo 
  /// or redo operations performed complete _false_, if the schedule does not 
  /// contain the given action, or if the schedule is [busy].
  Future<bool> to(action) { 
    var completer = new Completer();    
    if (!_actions.contains(action) || 
        !(_state == STATE_TO || _state == STATE_IDLE)) {
      completer.complete(false);
    } else {      
      _state = STATE_TO;
      _to(action, completer);
    }
    return completer.future;
  }
  
  void _to(action, completer) {
    final handleError = (e) { _error = e; completer.completeError(e); };
    final int actionIndex = _actions.indexOf(action);
    if (actionIndex == _nextUndo) {
      // Complete before we flush pending and transition to idle.
      // This ensures that continuations of 'to' see the state as the 
      // result of 'to' and _not_ the state of further pending actions.
      completer.complete(true);
      _flush();
    } else if (actionIndex < _nextUndo) {
      // Undo towards the desired action.
      undo()
        .then((success) {
          if (!success) completer.complete(false);
          else _to(action, completer);
        })
        .catchError(handleError);
    } else {
      // Redo towards the desired action.
      redo()
        .then((success) {
          if (!success) completer.complete(false); 
          else _to(action, completer);
        })
        .catchError(handleError);
    }
  }
  
  /// Redo the next action to be redone in this schedule, if any.
  /// Completes _true_ if an action was redone or else completes _false_.
  Future<bool> redo() { 
    var completer = new Completer<bool>();
    if(!_canRedo || !(_state == STATE_TO || _state == STATE_IDLE)) {
      completer.complete(false);
    } else {
      if (_state == STATE_IDLE) _state = STATE_REDO;
      final action = _actions[_nextUndo + 1];
      action._execute()
        .then((result) {
          _nextUndo++;
          action._result = result;
          // Complete before we flush pending and transition to idle.
          // This ensures that continuations of redo see the state as the 
          // result of redo and _not_ the state of further pending actions. 
          completer.complete(true);
          // Don't flush if we are in STATE_TO, it will flush when it is done.
          if (_state == STATE_REDO) _flush();
        })
        .catchError((e) {
          _error = e;
          completer.completeError(e);
        });
    }
    return completer.future;
  }
  
  /// Undo the next action to be undone in this schedule, if any.
  /// Completes _true_ if an action was undone or else completes _false_.
  Future<bool> undo() { 
    var completer = new Completer<bool>();
    if(!_canUndo || !(_state == STATE_TO || _state == STATE_IDLE)) {
      completer.complete(false);
    } else {
      if (_state == STATE_IDLE) _state = STATE_UNDO;
      final action = _actions[_nextUndo];
      action._unexecute()                
        .then((_) {
          _nextUndo--;
          // Complete before we flush pending and transition to idle.
          // This ensures that continuations of undo see the state as the 
          // result of undo and _not_ the state of further pending actions. 
          completer.complete(true);
          // Don't flush if we are in STATE_TO, it will flush when it is done.
          if (_state == STATE_UNDO) _flush();
        })
        .catchError((e) {
          _error = e;
          completer.completeError(e);
        });
    }
    return completer.future;
  }
}
