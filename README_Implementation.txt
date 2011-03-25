README for Distributed Systems VT11 Project

Concurrency Control through Timestamp Ordering as described at 
	http://en.wikipedia.org/w/index.php?title=Timestamp-based_concurrency_control&oldid=410754608

Modifications:
	When action is 'write' and WTS > TS, we abort instead of applying Thomas Write Rule.
	This is done because the rollback action of aborting a transaction can make
	the application of the Thomas Write rule invalid.

Data:
  ClientList is list of tuples like {Client,TS,DEP,OLD}
  Client is client Pid
  TS
    Transaction timestamp generated from running transaction count each time a client sends 'request'.
    This assumes each client only attempts one transaction at a time, which is 
    consistent with the client implementation given.
  DEP
    int timestamp
    Erlang Set of transactions that a given transaction depends on. Cleared when transaction ends.
  OLD
	List of old objects, stored when transaction writes a new value, to be able to roll back if
    it must abort. Only stored first time, not replaced by later writes.
	Database is list of tuples like {Idx, Val, RTS, WTS} where Idx is one of a..d and Val is stored int value.
  RTS
    int timestamp
  WTS
    int timestamp
  TrnHist
    Transaction history: a list of tuples {TS,Status} where TS is transaction timestamp
    and Status is one of running, committed, aborted. Only added to in this implementation.
    An improvement would be to check every now and then if there are any transactions that
    no running transaction depends on, and delete them.
Function:
  Start transaction
    Increment transaction count, 
    assign value to client as new transaction timestamp, 
    continue server loop with transaction count and ClientList
  Action
    Send database the action
    wait for database to say it was ok or that transaction should abort.
    update DEP or OLD depending on what action it was
    continue server loop with new ClientList
  Confirm
    Spawn process to to check whether all depended-on transactions have completed
      confirm if for each TS in Dep, the transaction status in TrnHist is committed.
    continue server loop
  Abort
    send rollback and OLD to database
    wait for rollback to complete
    end transaction
    continue server loop

Satisfaction of properties:
  Avoids deadlock
    Committing a transaction blocks only the checking process while there are incomplete
    transactions in the depends-on set DEP of the transaction, and by the
    read-rule, transactions in DEP for Ti must have TS < Ti, thus deadlock is
    avoided because no Tj in DEP(Ti) can be in DEP(Tj) (no cycles).
  Recoverable
    Doesn't commit if it read a value written by an earlier transaction which aborted:
    

