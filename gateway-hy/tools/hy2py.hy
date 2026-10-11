;; Render the Hy gateway as Python (the py side of the py <-> hy mapping).
;;
;;   python -m hy tools/hy2py.hy            # write py/kotoba_gateway/*.py
;;   python -m hy tools/hy2py.hy --check    # compile every module, write nothing
;;
;; The generated files are a read-only view for reviewers and for diffing
;; against upstream Hermes Python. The Hy sources stay authoritative, and py/
;; is gitignored.

(import argparse ast os sys
        hy.compiler)

(setv HERE (os.path.dirname (os.path.abspath __file__))
      ROOT (os.path.dirname HERE)
      PACKAGE "kotoba_gateway"
      HEADER "# Generated from {src} by tools/hy2py.hy. Do not edit; edit the .hy source.\n")

(defn hy-modules []
  (setv pkg (os.path.join ROOT PACKAGE))
  (sorted (gfor name (os.listdir pkg) :if (.endswith name ".hy") (os.path.join pkg name))))

(defn to-python [path]
  "Python source for one Hy module (compiled with Hy's own compiler)."
  (with [f (open path :encoding "utf-8")]
    (setv source (.read f)))
  (setv module f"{PACKAGE}.{(get (os.path.splitext (os.path.basename path)) 0)}"
        tree (hy.compiler.hy-compile (hy.read-many source :filename path) module
                                     :filename path :source source))
  (+ (ast.unparse tree) "\n"))

(defn main [[argv None]]
  (setv p (argparse.ArgumentParser :description "Render the Hy gateway as Python."))
  (.add_argument p "--check" :action "store_true")
  (.add_argument p "--out" :default (os.path.join ROOT "py"))
  (setv args (.parse_args p argv)
        out-pkg (os.path.join args.out PACKAGE))
  (for [path (hy-modules)]
    (setv rel (os.path.relpath path ROOT)
          code (to-python path))
    (compile code rel "exec")          ; the Python view must be valid Python
    (if args.check
        (print f"ok  {rel}")
        (do (os.makedirs out-pkg :exist_ok True)
            (setv target (os.path.join out-pkg (+ (cut (os.path.basename path) None -3) ".py")))
            (with [f (open target "w" :encoding "utf-8")]
              (.write f (+ (.format HEADER :src rel) code)))
            (print f"{rel} -> {(os.path.relpath target ROOT)}"))))
  0)

(when (= __name__ "__main__")
  (sys.exit (main)))
