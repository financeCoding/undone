
/// A little undo-redo library.
library undone;

import 'dart:async';

typedef R Do<A, R>(A arg);
typedef Future<R> DoAsync<A, R>(A arg);
typedef void Undo<A, R>(A arg, R result);
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

class Action<A, R> { 
  final A _arg;
  R _result; // The result of the most recent call().
  final DoAsync _do;
  final UndoAsync _undo;
  Completer _deferred;
  
  Action(A arg, Do d, Undo u) : this._(arg,
    d == null ? d : (a) => new Future.of(() => d(a)), 
    u == null ? u : (a, r) => new Future.of(() => u(a, r)));
  
  Action.async(A arg, DoAsync d, UndoAsync u) : this._(arg, d, u);
  
  Action._(this._arg, this._do, this._undo) {
    if (_do == null) throw new ArgumentError('Do function must be !null.');
    if (_undo == null) throw new ArgumentError('Undo function must be !null.');
  }
  
  /// Schedule this action to be called on the top-level [schedule].  If this
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
            (e) => throw new StateError('Error wrongfully caught.'), 
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

class TransactionError {
  final cause;
  var _rollbackError;
  get rollbackError => _rollbackError;
  TransactionError(this.cause);
}

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
  
  Transaction() : super._(new List<Action>(), _do_, _undo_);
  
  /// Adds the given [action] to this transaction.
  void add(Action action) => _arg.add(action);
}

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
  // Actions that are called while the schedule is busy are pending to be done.
  final _pending = new List<Action>();
  int _nextUndo = -1;
  int _currState = STATE_IDLE;
  var _err;
  
  /// Gets whether or not this schedule is busy performing another action.
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
  
  /// Whether or not the schedule has an [error].
  bool get hasError => _state == STATE_ERROR;
    
  /// The current error, if [hasError] is _true_.  The schedule will remain
  /// [busy] for as long as the schedule [hasError].  You may [clear] the
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
      final handleError = (e) { _error = e; completer.completeError(e); };
      final int actionIndex = _actions.indexOf(action);      
      if (actionIndex == _nextUndo) {
        // Reached the desired action, flush and complete with success.
        _flush().then((_) => completer.complete(true));
      } else if (actionIndex < _nextUndo) {
        // Undo towards the desired action.
        undo()
          .then((success) {
            if (!success) completer.complete(false);
            else to(action)
                .then((success) => completer.complete(success))
                .catchError(handleError);
          })
          .catchError(handleError);
      } else {
        // Redo towards the desired action.
        redo()
          .then((success) {
            if (!success) completer.complete(false); 
            else to(action)
                .then((success) => completer.complete(success))
                .catchError(handleError);
          })
          .catchError(handleError);
      }
    }
    return completer.future;
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
          if (_state == STATE_REDO) {
            // Redo was successful regardless of what happens in flush so we 
            // complete(true); any errors thrown in flush are handled there.
            _flush().then((_) => completer.complete(true));
          }
          // Don't flush if we are in STATE_TO, it will flush when it is done.
          else completer.complete(true);
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
          if (_state == STATE_UNDO) {
            // Undo was successful regardless of what happens in flush so we 
            // complete(true); any errors thrown in flush are handled there.
            _flush().then((_) => completer.complete(true));
          }
          // Don't flush if we are in STATE_TO, it will flush when it is done.
          else completer.complete(true);
        })
        .catchError((e) {
          _error = e;
          completer.completeError(e);
        });
    }
    return completer.future;
  }
}