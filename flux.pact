(define-keyset 'trunk (read-keyset 'trunk))

(namespace (read-msg 'ns))
(module testflux GOVERNANCE

  (implements fungible-v2)
  (use fungible-util)

  (defschema entry
    balance:decimal
    guard:guard)

  (deftable ledger:{entry})

  (defcap GOVERNANCE ()
    (enforce-guard
      (keyset-ref-guard 'trunk)))

  (defcap DEBIT (sender:string)
    (enforce-guard (at 'guard (read ledger sender))))

  (defcap CREDIT (receiver:string) true)

  (defcap TRANSFER:bool
    ( sender:string
      receiver:string
      amount:decimal
    )
    @managed amount TRANSFER-mgr
    (enforce-valid-transfer sender receiver (precision) amount)
    (compose-capability (DEBIT sender))
    (compose-capability (CREDIT receiver))
  )

  (defun TRANSFER-mgr:decimal
    ( managed:decimal
      requested:decimal
    )

    (let ((newbal (- managed requested)))
      (enforce (>= newbal 0.0)
        (format "TRANSFER exceeded for balance {}" [managed]))
      newbal)
  )

  (defconst MINIMUM_PRECISION 8)

  (defun enforce-unit:bool (amount:decimal)
    (enforce-precision (precision) amount))

  (defun create-account:string
    ( account:string
      guard:guard
    )
    (enforce-valid-account account)
    (insert ledger account
      { "balance" : 0.0
      , "guard"   : guard
      })
    )

  (defun get-balance:decimal (account:string)
    (at 'balance (read ledger account))
  )

  (defun details:object{fungible-v2.account-details}
    ( account:string )
    (with-read ledger account
      { "balance" := bal
      , "guard" := g }
      { "account" : account
      , "balance" : bal
      , "guard": g })
    )

  (defun rotate:string (account:string new-guard:guard)
    (with-read ledger account
      { "guard" := old-guard }

      (enforce-guard old-guard)

      (update ledger account
        { "guard" : new-guard }))
    )

  (defun fund:string (account:string amount:decimal)
    (with-capability (GOVERNANCE)
      (with-capability (CREDIT account)
        (credit account
          (at 'guard (read ledger account))
          amount))))

  (defun precision:integer ()
      MINIMUM_PRECISION)

  (defun transfer:string (sender:string receiver:string amount:decimal)

    (enforce (!= sender receiver)
      "sender cannot be the receiver of a transfer")
    (enforce-valid-transfer sender receiver (precision) amount)

    (with-capability (TRANSFER sender receiver amount)
      (debit sender amount)
      (with-read ledger receiver
        { "guard" := g }
        (credit receiver g amount))
      )
    )

  (defun transfer-create:string
    ( sender:string
      receiver:string
      receiver-guard:guard
      amount:decimal )

    (enforce (!= sender receiver)
      "sender cannot be the receiver of a transfer")
    (enforce-valid-transfer sender receiver (precision) amount)

    (with-capability (TRANSFER sender receiver amount)
      (debit sender amount)
      (credit receiver receiver-guard amount))
    )

  (defun debit:string (account:string amount:decimal)

    (require-capability (DEBIT account))
    (with-read ledger account
      { "balance" := balance }

      (enforce (<= amount balance) "Insufficient funds")

      (update ledger account
        { "balance" : (- balance amount) }
        ))
    )


  (defun credit:string (account:string guard:guard amount:decimal)

    (require-capability (CREDIT account))
    (with-default-read ledger account
      { "balance" : 0.0, "guard" : guard }
      { "balance" := balance, "guard" := retg }
      ; we don't want to overwrite an existing guard with the user-supplied one
      (enforce (= retg guard)
        "account guards do not match")

      (write ledger account
        { "balance" : (+ balance amount)
        , "guard"   : retg
        })
      ))

  (defschema crosschain-schema
    @doc "Schema for yielded value in cross-chain transfers"
    receiver:string
    receiver-guard:guard
    amount:decimal)

  (defpact transfer-crosschain:string
    ( sender:string
      receiver:string
      receiver-guard:guard
      target-chain:string
      amount:decimal )
    (step
      (with-capability (DEBIT sender)

        (enforce-valid-amount (precision) amount)
        (enforce-valid-account sender)
        (enforce-valid-account receiver)

        (enforce (!= "" target-chain) "empty target-chain")
        (enforce (!= (at 'chain-id (chain-data)) target-chain)
          "cannot run cross-chain transfers to the same chain")

          ;; step 1 - debit delete-account on current chain
          (debit sender amount)

          (let
            ((crosschain-details:object{crosschain-schema}
              { "receiver" : receiver
              , "receiver-guard" : receiver-guard
              , "amount" : amount
              }))
              (yield crosschain-details target-chain)
              )))

    (step
      (resume
        { "receiver" := receiver
        , "receiver-guard" := receiver-guard
        , "amount" := amount
        }

        ;; step 2 - credit create account on target chain
        (with-capability (CREDIT receiver)
          (credit receiver receiver-guard amount))
          ))
  )
)

(if (read-msg 'upgrade)
  ["upgrade"]
  [(create-table ledger)]
)
