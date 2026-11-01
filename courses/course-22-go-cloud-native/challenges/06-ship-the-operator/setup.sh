#!/usr/bin/env bash
# Plants the "Ship the Operator" starter — a complete, buildable Widget operator.
# The learner's job is to build the image, load it to kind, and apply the manifests.
# Idempotent — re-running overwrites files but does not delete go module cache.
set -euo pipefail

SLUG="06-ship-the-operator"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/config/crd"
mkdir -p "$WORK/config/rbac"
mkdir -p "$WORK/config/manager"

# ── go.mod ────────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'EOF'
module dojo/widget-operator

go 1.22

require (
	k8s.io/api v0.29.3
	k8s.io/apimachinery v0.29.3
	sigs.k8s.io/controller-runtime v0.17.3
)
EOF

# ── main.go — complete single-file operator ───────────────────────────────────
cat > "$WORK/main.go" << 'GOEOF'
package main

import (
	"context"
	"fmt"
	"os"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

// ── Widget CRD types ──────────────────────────────────────────────────────────

var widgetGVK = schema.GroupVersion{Group: "dojo.dev", Version: "v1"}

// Widget is the custom resource this operator manages.
type Widget struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              WidgetSpec `json:"spec,omitempty"`
}

// WidgetSpec declares the desired state of a Widget.
type WidgetSpec struct {
	// Replicas is the number of pods the backing Deployment should run.
	Replicas int32 `json:"replicas,omitempty"`
	// Image is the container image for the backing Deployment.
	Image string `json:"image,omitempty"`
}

func (w *Widget) DeepCopyObject() runtime.Object {
	out := *w
	return &out
}

type WidgetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Widget `json:"items"`
}

func (w *WidgetList) DeepCopyObject() runtime.Object {
	out := *w
	out.Items = append([]Widget{}, w.Items...)
	return &out
}

var scheme = func() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = appsv1.AddToScheme(s)
	_ = corev1.AddToScheme(s)
	s.AddKnownTypes(widgetGVK, &Widget{}, &WidgetList{})
	metav1.AddToGroupVersion(s, widgetGVK)
	return s
}()

// ── WidgetReconciler ──────────────────────────────────────────────────────────

type WidgetReconciler struct {
	client.Client
}

func (r *WidgetReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := ctrl.LoggerFrom(ctx)

	widget := &Widget{}
	if err := r.Get(ctx, req.NamespacedName, widget); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	replicas := widget.Spec.Replicas
	if replicas == 0 {
		replicas = 1
	}
	image := widget.Spec.Image
	if image == "" {
		image = "nginx:1.27-alpine"
	}

	log.Info("reconciling Widget", "name", widget.Name, "replicas", replicas, "image", image)

	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "widget-" + widget.Name,
			Namespace: widget.Namespace,
		},
	}
	_, err := ctrl.CreateOrUpdate(ctx, r.Client, deploy, func() error {
		deploy.Spec = appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"widget": widget.Name},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"widget": widget.Name},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{Name: "widget", Image: image},
					},
				},
			},
		}
		return nil
	})
	return ctrl.Result{}, err
}

func (r *WidgetReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&Widget{}).
		Complete(r)
}

// ── main ──────────────────────────────────────────────────────────────────────

func main() {
	ctrl.SetLogger(zap.New())

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{Scheme: scheme})
	if err != nil {
		fmt.Fprintf(os.Stderr, "unable to create manager: %v\n", err)
		os.Exit(1)
	}

	if err = (&WidgetReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		fmt.Fprintf(os.Stderr, "unable to setup WidgetReconciler: %v\n", err)
		os.Exit(1)
	}

	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		fmt.Fprintf(os.Stderr, "manager exited with error: %v\n", err)
		os.Exit(1)
	}
}
GOEOF

# ── Dockerfile ────────────────────────────────────────────────────────────────
cat > "$WORK/Dockerfile" << 'EOF'
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -o /manager .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /manager /manager
ENTRYPOINT ["/manager"]
EOF

# ── config/crd/widget-crd.yaml ────────────────────────────────────────────────
cat > "$WORK/config/crd/widget-crd.yaml" << 'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.dojo.dev
spec:
  group: dojo.dev
  names:
    kind: Widget
    listKind: WidgetList
    plural: widgets
    singular: widget
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              replicas:
                type: integer
                minimum: 0
              image:
                type: string
EOF

# ── config/rbac/rbac.yaml ─────────────────────────────────────────────────────
cat > "$WORK/config/rbac/rbac.yaml" << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: widget-controller-manager
  namespace: dojo-operator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: widget-controller-manager-role
rules:
- apiGroups: ["dojo.dev"]
  resources: ["widgets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: widget-controller-manager-rolebinding
subjects:
- kind: ServiceAccount
  name: widget-controller-manager
  namespace: dojo-operator
roleRef:
  kind: ClusterRole
  name: widget-controller-manager-role
  apiGroup: rbac.authorization.k8s.io
EOF

# ── config/manager/manager.yaml ───────────────────────────────────────────────
cat > "$WORK/config/manager/manager.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: widget-controller-manager
  namespace: dojo-operator
  labels:
    control-plane: controller-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      control-plane: controller-manager
  template:
    metadata:
      labels:
        control-plane: controller-manager
    spec:
      serviceAccountName: widget-controller-manager
      containers:
      - name: manager
        image: widget-controller:dev
        imagePullPolicy: IfNotPresent
        command: ["/manager"]
EOF

echo
echo "Work directory  : $WORK"
echo
echo "Prereqs         : Docker Desktop running, kind cluster 'dojo' active,"
echo "                  Go 1.22+ installed"
echo
echo "Steps:"
echo "  1.  cd $WORK"
echo "  2.  go mod tidy"
echo "  3.  docker build -t widget-controller:dev ."
echo "  4.  kind load docker-image widget-controller:dev --name dojo"
echo "  5.  kubectl create namespace dojo-operator --dry-run=client -o yaml | kubectl apply -f -"
echo "  6.  kubectl apply -f config/crd/"
echo "  7.  kubectl wait --for=condition=Established crd/widgets.dojo.dev --timeout=30s"
echo "  8.  kubectl apply -f config/rbac/"
echo "  9.  kubectl apply -f config/manager/"
echo "  10. kubectl -n dojo-operator rollout status deployment/widget-controller-manager --timeout=90s"
echo
echo "Verify + flag   : bash courses/course-22-go-cloud-native/challenges/06-ship-the-operator/verify.sh"
