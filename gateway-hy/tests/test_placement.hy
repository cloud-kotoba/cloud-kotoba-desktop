;; Placement without a central store: operator-signed manifests, computed
;; ownership, liveness from peers' signed node manifests.

(import json os tempfile threading unittest
        urllib.request [Request urlopen]
        urllib.error [HTTPError]
        kotoba_gateway.identity [NodeIdentity]
        kotoba_gateway.placement [Placement build-manifest is-valid-manifest]
        kotoba_gateway.backend [EchoBackend]
        kotoba_gateway.server [make-server])
(import tests.test_shard [Clock T0])

(defclass Base [unittest.TestCase]
  (defn setUp [self]
    (setv self.tmp (tempfile.TemporaryDirectory)
          self.op (NodeIdentity.generate)
          self.a (NodeIdentity.generate)
          self.b (NodeIdentity.generate)
          self.clock (Clock T0)))
  (defn tearDown [self] (.cleanup self.tmp))

  (defn nodes [self]
    [{"did" self.a.did "url" "http://a" "residency" ["anonymous" "attested"] "caps" ["python3"]}
     {"did" self.b.did "url" "http://b" "residency" ["anonymous"] "caps" ["python3"]}])

  (defn manifest [self profiles [version 1] [signer None]]
    (build-manifest (or signer self.op) (.nodes self) profiles :version version :now T0))

  (defn view [self node [fetch None] [on-change None] [name "pl.json"]]
    (Placement node self.op.did (os.path.join self.tmp.name (+ (cut node.did -6) name))
               :clock self.clock :fetch (or fetch (fn [url] None)) :on-change on-change))

  (defn node-manifest [self node issued-at]
    (.sign-document node {"type" "kotoba.node" "did" node.did "issued_at" issued-at})))

(defclass Manifests [Base]
  ;; @lat: [[profile-distribution#Placement#Tests#Only newer operator-signed manifests are adopted]]
  (defn test-adoption-rules [self]
    (setv v (.view self self.a) m (.manifest self [{"id" "p" "pin" self.a.did}] :version 5))
    (.assertTrue self (is-valid-manifest m self.op.did))
    (.assertFalse self (.adopt v (.manifest self [] :version 9 :signer self.b)) "wrong signer")
    (setv tampered (dict m)) (setv (get tampered "version") 99)
    (.assertFalse self (.adopt v tampered) "tampered")
    (.assertTrue self (.adopt v m))
    (.assertFalse self (.adopt v (.manifest self [] :version 5)) "same version")
    (.assertFalse self (.adopt v (.manifest self [] :version 4)) "older")
    ;; persisted: a fresh view of the same node reloads it
    (.assertEqual self (.version (.view self self.a)) 5)))

(defclass Ownership [Base]
  ;; @lat: [[profile-distribution#Placement#Tests#A pinned profile has exactly one owner]]
  (defn test-pins [self]
    (setv m (.manifest self [{"id" "mine" "pin" self.a.did} {"id" "theirs" "pin" self.b.did}
                             {"id" "orphan" "pin" "did:key:z6MkNotInManifest"}])
          va (.view self self.a) vb (.view self self.b))
    (.adopt va m) (.adopt vb m)
    (.assertEqual self (.allowed-set va) (frozenset ["mine"]))
    (.assertEqual self (.allowed-set vb) (frozenset ["theirs"]))
    ;; a pin holds even when its node is not seen alive: the profile waits
    (setv self.clock.t (+ T0 99999))
    (.assertEqual self (.allowed-set va) (frozenset ["mine"]))
    (.assertEqual self (.allowed-set vb) (frozenset ["theirs"])))

  ;; @lat: [[profile-distribution#Placement#Tests#A held profile has no owner until a newer manifest drops the hold]]
  (defn test-hold [self]
    (setv va (.view self self.a))
    (.adopt va (.manifest self [{"id" "mine" "pin" self.a.did}
                                {"id" "broken" "pin" self.a.did "hold" "unknown bot"}
                                {"id" "floating" "hold" "unknown bot"}]))
    (.assertEqual self (.allowed-set va) (frozenset ["mine"]))
    (.adopt va (.manifest self [{"id" "mine" "pin" self.a.did} {"id" "broken" "pin" self.a.did}]
                          :version 2))
    (.assertEqual self (.allowed-set va) (frozenset ["mine" "broken"])))

  ;; @lat: [[profile-distribution#Placement#Tests#An unpinned profile moves only after its owner is silent for a TTL]]
  (defn test-unpinned-failover [self]
    (setv profiles (lfor i (range 40) {"id" f"p{i}" "caps" ["python3"]})
          m (.manifest self profiles)
          va (.view self self.a))
    (.adopt va m)
    (.assertTrue self (.note-node-manifest va (.node-manifest self self.b T0)))
    (setv split (.allowed-set va))
    (.assertTrue self (< 0 (len split) 40) "both live: the profiles split")
    ;; b goes silent; within the TTL a keeps only its own share
    (setv self.clock.t (+ T0 599))
    (.assertEqual self (.allowed-set va) split)
    ;; after a full TTL a takes everything
    (setv self.clock.t (+ T0 600))
    (.assertEqual self (len (.allowed-set va)) 40)
    ;; a stale or future-dated node manifest is not proof of life
    (.assertFalse self (.note-node-manifest va (.node-manifest self self.b (- (+ T0 600) 601))))
    (.assertFalse self (.note-node-manifest va (.node-manifest self self.b (+ T0 600 120)))))

  ;; @lat: [[profile-distribution#Placement#Tests#Residency and capabilities limit owners]]
  (defn test-eligibility [self]
    (setv m (.manifest self [{"id" "secret" "residency" "attested"}
                             {"id" "gpu" "caps" ["gpu"]}])
          va (.view self self.a) vb (.view self self.b))
    (.adopt va m) (.adopt vb m)
    (.note-node-manifest vb (.node-manifest self self.a T0))
    (.assertIn self "secret" (.allowed-set va) "only a is attested")
    (.assertNotIn self "secret" (.allowed-set vb))
    (.assertNotIn self "gpu" (| (.allowed-set va) (.allowed-set vb)) "nobody has a gpu")))

(defclass Sync [Base]
  ;; @lat: [[profile-distribution#Placement#Tests#Manifests and liveness travel between peers]]
  (defn test-sync-from-peer [self]
    (setv newer (.manifest self [{"id" "x" "pin" self.a.did}] :version 7)
          node-b (.node-manifest self self.b T0)
          changes [])
    (defn fetch [url]
      (cond (.endswith url "/.well-known/kotoba-node") node-b
            (.endswith url "/v1/placement") newer))
    (setv va (.view self self.a :fetch fetch :on-change (fn [s] (.append changes s))))
    (.adopt va (.manifest self [] :version 1))
    (.sync-once va)
    (.assertEqual self (.version va) 7)
    (.assertTrue self (.is-live va self.b.did))
    (.assertEqual self changes [(frozenset ["x"])])))

(defclass Http [Base]
  ;; @lat: [[profile-distribution#Placement#Tests#The gateway serves and adopts manifests]]
  (defn test-gateway-routes [self]
    (setv key "pl-key-0123456789abcdef"
          [server gw] (make-server "127.0.0.1" 0 (EchoBackend) key :state-dir self.tmp.name)
          base gw.public-url)
    (setv gw.placement (Placement gw.node self.op.did (os.path.join self.tmp.name "p.json")))
    (.start (threading.Thread :target server.serve_forever :daemon True))
    (defn call [method path [body None] [headers None]]
      (setv req (Request (+ base path) :method method
                         :data (when body (.encode (json.dumps body)))))
      (for [[k v] (.items (or headers {"Authorization" (+ "Bearer " key)}))] (.add_header req k v))
      (try (with [r (urlopen req)] [r.status (json.loads (.read r))])
           (except [e HTTPError] [e.code None])))
    (try
      (.assertEqual self (get (call "GET" "/v1/placement") 0) 404)
      (setv m (build-manifest self.op [{"did" gw.node.did "url" base} {"did" self.b.did "url" "http://b"}]
                              [{"id" "p" "pin" gw.node.did}] :version 3))
      (.assertEqual self (call "PUT" "/v1/placement" m) [200 {"adopted" 3 "allowed" 1}])
      (.assertEqual self (get (call "PUT" "/v1/placement" m) 0) 409)
      (.assertEqual self (get (call "GET" "/v1/placement") 1 "version") 3)
      ;; a node named in the manifest is trusted without explicit trust
      (setv hdrs (.request-headers self.b "GET" "/v1/placement" b""))
      (.assertEqual self (get (call "GET" "/v1/placement" :headers hdrs) 0) 200)
      ;; ... but may not push manifests (local only)
      (setv raw (.encode (json.dumps m)))
      (.assertEqual self (get (call "PUT" "/v1/placement" m (.request-headers self.b "PUT" "/v1/placement" raw)) 0) 403)
      (finally (.shutdown server) (.server_close server)))))

(when (= __name__ "__main__")
  (unittest.main))
