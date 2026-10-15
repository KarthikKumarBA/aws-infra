# Native RBAC for the GitHub deploy role (Kubernetes group "github-deployers"):
# the built-in "admin" ClusterRole, bound only inside each app namespace.
# Needed so CD can create the app's own Roles/RoleBindings (RBAC escalation prevention).
resource "kubernetes_role_binding_v1" "deployers" {
  for_each = kubernetes_namespace_v1.apps

  metadata {
    name      = "github-deployers-admin"
    namespace = each.value.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = local.deployer_group
  }
}
