//! Future sole owner of prepare/apply/verify/commit/restore and active selection.
//! Depends on domain contracts, engine adapters and the routing platform.
//! No daemon, command queue, lock acquisition or lifecycle implementation yet.
//! Pure health/selection lives in mors-domain; registry, secret store and observability are deferred;
//! this crate must not duplicate their policies or equate readiness with health.
