;; merit-badge.clar
;; On-chain skill credentialing registry.
;; Authorities issue, renew, and revoke typed badges. External contracts gate on badge validity.

;; STORAGE

(define-map authorities
    { issuer: principal }
    {
        display-name: (string-utf8 80),
        quota-per-epoch: uint,
        issued-this-epoch: uint,
        epoch-started-at: uint,
        is-active: bool
    }
)

(define-map badge-types
    { issuer: principal, type-id: uint }
    {
        label: (string-utf8 60),
        expiry-blocks: uint,    ;; 0 = non-expiring
        is-transferable: bool
    }
)

(define-map issuances
    { holder: principal, issuer: principal, type-id: uint }
    {
        issued-at: uint,
        expires-at: uint,       ;; 0 = non-expiring
        is-revoked: bool
    }
)

(define-data-var deployer principal tx-sender)
(define-data-var total-issued uint u0)

;; CONSTANTS

(define-constant ERR-ONLY-DEPLOYER    u50)
(define-constant ERR-ALREADY-EXISTS   u51)
(define-constant ERR-NOT-AUTHORITY    u52)
(define-constant ERR-AUTH-INACTIVE    u53)
(define-constant ERR-QUOTA-EXCEEDED   u54)
(define-constant ERR-NO-BADGE-TYPE    u55)
(define-constant ERR-NO-ISSUANCE      u56)
(define-constant ERR-ALREADY-ISSUED   u57)
(define-constant ERR-ALREADY-REVOKED  u58)
(define-constant ERR-EMPTY-NAME       u59)

;; PRIVATE HELPERS

(define-private (only-deployer)
    (is-eq tx-sender (var-get deployer))
)

(define-private (authority-ok (issuer principal))
    (match (map-get? authorities { issuer: issuer })
        a (get is-active a)
        false
    )
)

(define-private (compute-expiry (expiry-blocks uint))
    (if (is-eq expiry-blocks u0)
        u0
        (+ block-height expiry-blocks)
    )
)

(define-private (badge-is-valid (holder principal) (issuer principal) (type-id uint))
    (match (map-get? issuances { holder: holder, issuer: issuer, type-id: type-id })
        rec (and
                (not (get is-revoked rec))
                (or
                    (is-eq (get expires-at rec) u0)
                    (< block-height (get expires-at rec))
                ))
        false
    )
)

;; DEPLOYER FUNCTIONS

(define-public (register-authority
    (who principal)
    (display-name (string-utf8 80))
    (quota uint))

    (begin
        (asserts! (only-deployer) (err ERR-ONLY-DEPLOYER))
        (asserts! (is-none (map-get? authorities { issuer: who })) (err ERR-ALREADY-EXISTS))
        (asserts! (> (len display-name) u0) (err ERR-EMPTY-NAME))
        (asserts! (> quota u0) (err ERR-QUOTA-EXCEEDED))

        (map-set authorities { issuer: who }
            {
                display-name: display-name,
                quota-per-epoch: quota,
                issued-this-epoch: u0,
                epoch-started-at: block-height,
                is-active: true
            }
        )
        (ok true)
    )
)

(define-public (deactivate-authority (who principal))
    (begin
        (asserts! (only-deployer) (err ERR-ONLY-DEPLOYER))

        (let ((rec (unwrap! (map-get? authorities { issuer: who }) (err ERR-NOT-AUTHORITY))))
            (map-set authorities { issuer: who } (merge rec { is-active: false }))
            (ok true)
        )
    )
)

;; AUTHORITY FUNCTIONS

(define-public (define-badge-type
    (type-id uint)
    (label (string-utf8 60))
    (expiry-blocks uint))

    (begin
        (asserts! (authority-ok tx-sender) (err ERR-AUTH-INACTIVE))
        (asserts! (is-none (map-get? badge-types { issuer: tx-sender, type-id: type-id })) (err ERR-ALREADY-EXISTS))
        (asserts! (> (len label) u0) (err ERR-EMPTY-NAME))

        (map-set badge-types { issuer: tx-sender, type-id: type-id }
            {
                label: label,
                expiry-blocks: expiry-blocks,
                is-transferable: false
            }
        )
        (ok true)
    )
)

(define-public (issue-badge (recipient principal) (type-id uint))
    (begin
        (asserts! (authority-ok tx-sender) (err ERR-AUTH-INACTIVE))
        (asserts! (is-some (map-get? badge-types { issuer: tx-sender, type-id: type-id })) (err ERR-NO-BADGE-TYPE))
        (asserts!
            (is-none (map-get? issuances { holder: recipient, issuer: tx-sender, type-id: type-id }))
            (err ERR-ALREADY-ISSUED))

        (let (
            (auth (unwrap! (map-get? authorities { issuer: tx-sender }) (err ERR-NOT-AUTHORITY)))
            (btype (unwrap! (map-get? badge-types { issuer: tx-sender, type-id: type-id }) (err ERR-NO-BADGE-TYPE)))
        )
            (asserts!
                (< (get issued-this-epoch auth) (get quota-per-epoch auth))
                (err ERR-QUOTA-EXCEEDED))

            (map-set issuances
                { holder: recipient, issuer: tx-sender, type-id: type-id }
                {
                    issued-at: block-height,
                    expires-at: (compute-expiry (get expiry-blocks btype)),
                    is-revoked: false
                }
            )

            (map-set authorities { issuer: tx-sender }
                (merge auth { issued-this-epoch: (+ (get issued-this-epoch auth) u1) })
            )

            (var-set total-issued (+ (var-get total-issued) u1))
            (ok true)
        )
    )
)

(define-public (revoke-badge (holder principal) (type-id uint))
    (let ((rec (unwrap!
            (map-get? issuances { holder: holder, issuer: tx-sender, type-id: type-id })
            (err ERR-NO-ISSUANCE))))

        (asserts! (authority-ok tx-sender) (err ERR-AUTH-INACTIVE))
        (asserts! (not (get is-revoked rec)) (err ERR-ALREADY-REVOKED))

        (map-set issuances
            { holder: holder, issuer: tx-sender, type-id: type-id }
            (merge rec { is-revoked: true })
        )
        (ok true)
    )
)

;; Authority resets its own epoch counter to refresh quota
(define-public (reset-epoch)
    (let ((auth (unwrap! (map-get? authorities { issuer: tx-sender }) (err ERR-NOT-AUTHORITY))))
        (asserts! (get is-active auth) (err ERR-AUTH-INACTIVE))
        (map-set authorities { issuer: tx-sender }
            (merge auth {
                issued-this-epoch: u0,
                epoch-started-at: block-height
            })
        )
        (ok true)
    )
)

;; READ-ONLY

(define-read-only (check-badge (holder principal) (issuer principal) (type-id uint))
    (badge-is-valid holder issuer type-id)
)

(define-read-only (get-issuance (holder principal) (issuer principal) (type-id uint))
    (match (map-get? issuances { holder: holder, issuer: issuer, type-id: type-id })
        r (ok r) (err ERR-NO-ISSUANCE)
    )
)

(define-read-only (get-authority (who principal))
    (match (map-get? authorities { issuer: who })
        a (ok a) (err ERR-NOT-AUTHORITY)
    )
)

(define-read-only (get-badge-type (issuer principal) (type-id uint))
    (match (map-get? badge-types { issuer: issuer, type-id: type-id })
        b (ok b) (err ERR-NO-BADGE-TYPE)
    )
)

(define-read-only (total-badges-issued)
    (var-get total-issued)
)