;; Placement without a central store: which node runs which Hermes profile.
;;
;; The owner (2026-10-09) ruled out D1, R2 and KV for this. Placement is an
;; operator-signed manifest instead:
;;
;;   {"type" "kotoba.placement" "version" n "issued_at" t
;;    "nodes"    [{"did" "url" "residency" [...] "caps" [...] "weight" w} ...]
;;    "profiles" [{"id" "residency" "pin" "caps" "cost" "hold"} ...]
;;    "signer" operator-did "signature" ...}
;;
;; Every node holds a copy and adopts another only when it is signed by the
;; trusted operator did and carries a higher version. Copies travel over the
;; Kotoba mesh: nodes pull `GET /v1/placement` from the nodes the manifest
;; lists. The manifest is also the trust list: its nodes may call each other.
;;
;; Ownership is computed, not stored:
;;   - a pinned profile belongs to its pinned node. Nothing else is consulted,
;;     so two nodes can never both run it (a down pin node means the profile
;;     waits);
;;   - an unpinned profile belongs to the highest weighted-rendezvous score
;;     among nodes this node sees alive. A node is alive while its signed
;;     node manifest (`issued_at`) is fresh within TTL, so a node takes over
;;     only after the previous owner has been silent for a full TTL.
;;
;; Unpinned failover is best effort under asymmetric partitions (two nodes
;; can briefly disagree on who is alive). Pins give exactly-one; phase 3's
;; canary uses pins only.

(import hashlib json math os sys threading time
        urllib.request [Request urlopen]
        urllib.error [HTTPError URLError]
        kotoba_gateway.identity [is-signed])

(setv MANIFEST-TYPE "kotoba.placement"
      LIVENESS-TTL-SECONDS 600
      DEFAULT-INTERVAL-SECONDS 60
      MAX-FUTURE-SKEW 60)

;; ─── manifest ────────────────────────────────────────────────────────────

(defn is-valid-manifest [doc operator-did]
  "Signed by the operator, of the placement type, with an integer version."
  (and (isinstance doc dict)
       (= (.get doc "type") MANIFEST-TYPE)
       (isinstance (.get doc "version") int)
       (isinstance (.get doc "nodes") list)
       (isinstance (.get doc "profiles") list)
       (= (.get doc "signer") operator-did)
       (is-signed doc)))

(defn build-manifest [operator nodes profiles [version None] [now None]]
  "A signed manifest (operator is a NodeIdentity)."
  (setv now (or now (time.time)))
  (.sign-document operator {"type" MANIFEST-TYPE
                            "version" (or version (int (* 1000 now)))
                            "issued_at" now
                            "nodes" nodes
                            "profiles" profiles}))

;; ─── rendezvous hashing ──────────────────────────────────────────────────

(defn hrw-score [profile-id node]
  "weight / -ln(u), u in (0,1) from sha256(profile \\0 did). Deterministic on
  every node (all run this same function)."
  (setv digest (.digest (hashlib.sha256 (.encode (+ profile-id "\u0000" (get node "did")) "utf-8")))
        u (/ (+ (int.from_bytes (cut digest 8) "big") 0.5) (** 2 64))
        w (max 0.0001 (float (.get node "weight" 1))))
  (/ w (- (math.log u))))

(defn is-eligible [node profile]
  (and (.issuperset (set (.get node "caps" [])) (set (.get profile "caps" [])))
       (in (.get profile "residency" "anonymous") (.get node "residency" ["anonymous"]))))

;; ─── the placement view held by one node ─────────────────────────────────

(defn fetch-json [url headers [timeout 10]]
  "Decoded JSON from a GET, or None on any failure."
  (setv req (Request url :method "GET"))
  (for [[k v] (.items headers)] (.add_header req k v))
  (try
    (with [res (urlopen req :timeout timeout)]
      (json.loads (.read res)))
    (except [[HTTPError URLError OSError ValueError]] None)))

(defclass Placement []
  (defn __init__ [self node operator-did state-path
                  [ttl LIVENESS-TTL-SECONDS] [interval DEFAULT-INTERVAL-SECONDS]
                  [clock time.time] [fetch None] [on-change None]]
    (setv self.node node
          self.did node.did
          self.operator-did operator-did
          self.state-path state-path
          self.ttl ttl
          self.interval interval
          self.clock clock
          self.fetch (or fetch (fn [url] (fetch-json url (.request-headers node "GET" (path-of url) b""))))
          self.on-change on-change
          self.lock (threading.RLock)
          self.manifest None
          self.seen {}             ; did -> local time its signed manifest was last fresh
          self.last-allowed (frozenset)
          self.last-error None)
    (.load self)
    (setv self.last-allowed (.allowed-set self)))

  ;; -- manifest --

  (defn load [self]
    (try
      (with [f (open self.state-path :encoding "utf-8")]
        (setv doc (json.load f)))
      (except [[OSError ValueError]] (return)))
    (when (is-valid-manifest doc self.operator-did)
      (setv self.manifest doc)))

  (defn version [self]
    (if self.manifest (get self.manifest "version") 0))

  (defn adopt [self doc]
    "Take `doc` if it is operator-signed and newer. Returns True when adopted."
    (with [self.lock]
      (when (or (not (is-valid-manifest doc self.operator-did))
                (<= (get doc "version") (.version self)))
        (return False))
      (setv self.manifest doc)
      (os.makedirs (os.path.dirname (os.path.abspath self.state-path)) :exist_ok True)
      (setv tmp (+ self.state-path ".tmp"))
      (with [f (open tmp "w" :encoding "utf-8")] (json.dump doc f))
      (os.replace tmp self.state-path))
    (.recompute self)
    True)

  (defn nodes [self]
    (if self.manifest (get self.manifest "nodes") []))

  (defn node-entry [self did]
    (for [n (.nodes self)] (when (= (.get n "did") did) (return n)))
    None)

  (defn is-member [self did]
    "Nodes named in the current manifest trust each other."
    (is-not (.node-entry self did) None))

  ;; -- liveness --

  (defn is-live [self did [now None]]
    (setv now (or now (self.clock)))
    (or (= did self.did)
        (do (setv t (.get self.seen did))
            (and (is-not t None) (< (- now t) self.ttl)))))

  (defn note-node-manifest [self doc [now None]]
    "Record a peer's signed node manifest as proof it is alive now."
    (setv now (or now (self.clock)))
    (when (and (isinstance doc dict) (is-signed doc)
               (= (.get doc "type") "kotoba.node")
               (= (.get doc "did") (.get doc "signer"))
               (isinstance (.get doc "issued_at") #(int float))
               (< (- now (get doc "issued_at")) self.ttl)
               (< (- (get doc "issued_at") now) MAX-FUTURE-SKEW))
      (setv (get self.seen (get doc "did")) now)
      True))

  ;; -- ownership --

  (defn owner [self profile [now None]]
    "The did that should run `profile` (a manifest entry), or None. A held
    profile (`\"hold\" reason`) has no owner: no node ticks it until a newer
    manifest drops the hold. Its jobs.json is untouched."
    (setv now (or now (self.clock)))
    (when (.get profile "hold") (return None))
    (setv pin (.get profile "pin"))
    (if pin
        (when (.node-entry self pin) pin)
        (do (setv candidates (lfor n (.nodes self)
                                   :if (and (is-eligible n profile) (.is-live self (get n "did") now))
                                   n))
            (when candidates
              (get (max candidates :key (fn [n] (hrw-score (get profile "id") n))) "did")))))

  (defn allowed-set [self [now None]]
    (setv now (or now (self.clock)))
    (if (not self.manifest)
        (frozenset)
        (frozenset (gfor p (get self.manifest "profiles")
                         :if (= (.owner self p now) self.did)
                         (get p "id")))))

  (defn allows [self profile-id [now None]]
    "Without `now`, answers from the set cached by `recompute` (run on adopt
    and on every sync). The shard host asks once per profile per pass;
    recomputing here made each pass O(profiles^2) -- a million ownership
    checks on the workstation's 1,015 profiles."
    (if (is now None)
        (in profile-id self.last-allowed)
        (in profile-id (.allowed-set self now))))

  (defn recompute [self]
    (setv allowed (.allowed-set self))
    (when (!= allowed self.last-allowed)
      (setv self.last-allowed allowed)
      (when self.on-change (self.on-change allowed)))
    allowed)

  ;; -- sync with peers --

  (defn sync-once [self]
    "Probe every other manifest node: liveness from its node manifest, and a
    newer placement manifest if it has one."
    (for [n (list (.nodes self))]
      (setv did (.get n "did") url (.rstrip (or (.get n "url") "") "/"))
      (when (and url (!= did self.did))
        (.note-node-manifest self (self.fetch (+ url "/.well-known/kotoba-node")))
        (setv doc (self.fetch (+ url "/v1/placement")))
        (when doc (.adopt self doc))))
    (.recompute self))

  (defn run-forever [self stop-event]
    (while (not (.is-set stop-event))
      (try (.sync-once self)
           (except [e Exception]
             (setv self.last-error (repr e))
             (print f"[kotoba-placement] sync failed: {e !r}" :file sys.stderr)))
      (.wait stop-event self.interval)))

  (defn start [self]
    (setv stop (threading.Event))
    (.start (threading.Thread :target self.run-forever :args #(stop)
                              :name "kotoba-placement" :daemon True))
    stop)

  (defn status [self]
    (setv now (self.clock))
    {"operator" self.operator-did
     "version" (.version self)
     "nodes" (lfor n (.nodes self) {"did" (get n "did") "live" (.is-live self (get n "did") now)})
     "allowed" (len (.allowed-set self now))
     "last_error" self.last-error}))

(defn path-of [url]
  (setv rest (get (.split url "://" 1) -1))
  (if (in "/" rest) (+ "/" (get (.split rest "/" 1) 1)) "/"))
