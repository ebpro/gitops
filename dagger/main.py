# ruff: noqa: F401, F821
# Description: Pipeline definitions for build, scan, and deploy
# Documentation: https://docs.dagger.io

from dagger import container, Directory, File, Secret

class Pipeline:
    """Platform CI/CD pipeline for container builds and Helm deployments"""

    # Build a container image from a Dockerfile
    def build_image(self, context_src: Directory, dockerfile: File, platform_string="linux/amd64"):
        """Build a container image

        Args:
            context_src: Path containing the source and Dockerfile
            dockerfile: The Dockerfile to build
            platform_string: Target platform (default: linux/amd64)
        """
        return container().build_context(
            context=context_src,
            dockerfile=dockerfile
        ).as_platform(platform_string)

    # Scan image for vulnerabilities with Trivy
    def scan_image(self, img: container.Container, severity="HIGH,CRITICAL"):
        """Scan container image for security vulnerabilities

        Args:
            img: Container image to scan
            severity: Comma-separated severity levels
        """
        return container("docker.io/aquasec/trivy:latest").with_exec([
            "trivy", "image",
            "--severity", severity,
            "--exit-code", "1",
            "--format", "table",
            "--input", "/tmp/image.tar"
        ], _inputs={"image.tar": img.export("/tmp/image.tar")})

    # Generate SBOM with Syft
    def sbom(self, img: container.Container, sbom_format="cyclonedx-json", output_path="/tmp/sbom.json"):
        """Generate Software Bill of Materials for container image

        Args:
            img: Container image to generate SBOM for
            sbom_format: Output format (cyclonedx-json, spdx-json, etc.)
            output_path: Path to write SBOM file
        """
        return container("ghcr.io/anchore/syft/syft:latest").with_exec([
            syft, img.id(),
            "-o", sbom_format,
            output_path
        ]).file(output_path)

    # Push image to Harbor registry
    def push_image(self, img: container.Container, registry: Secret, username: Secret, password: Secret, tag: str):
        """Push container image to Harbor registry

        Args:
            img: Container image to push
            registry: Registry address secret
            username: Registry username secret
            password: Registry password secret
            tag: Image tag
        """
        return img.with_registry_auth(
            address="harbor.ebruno.fr",
            username=Secret(username),
            password=Secret(password)
        ).publish(f"harbor.ebruno.fr/library/{tag}")

    # Lint Helm charts
    def helm_lint(self, chart_path: Directory, values_file: File = None):
        """Lint Helm chart for syntax and best practices

        Args:
            chart_path: Directory containing the Helm chart
            values_file: Optional values file to test against
        """
        cmd = ["helm", "lint", "/chart"]
        if values_file:
            cmd.extend(["-f", "/values.yaml"])
        return container("alpine/helm:latest").with_mounted_files(
            "/chart", chart_path
        ).with_file("/values.yaml", values_file, values_file is not None).with_exec(cmd)

    # Validate K8s manifests with kubeval
    def validate_manifests(self, k8s_dir: Directory):
        """Validate Kubernetes manifests against the K8s API schema

        Args:
            k8s_dir: Directory containing Kubernetes manifests
        """
        return container("alpine/kubeval:latest").with_mounted_files(
            "/k8s", k8s_dir
        ).with_exec(["kubeval", "/k8s"])

    # Full CI pipeline: build -> scan -> SBOM -> lint -> push
    def ci_pipeline(self, src_dir: Directory, dockerfile: File,
                     tag: str | None = None,
                     registry_username: Secret | None = None,
                     registry_password: Secret | None = None,
                     helm_chart_dir: Directory | None = None):
        """Execute full CI pipeline

        Args:
            src_dir: Source directory containing the application
            dockerfile: Dockerfile to build
            tag: Image tag. Required for push step.
            registry_username: Harbor registry username
            registry_password: Harbor registry password
            helm_chart_dir: Optional Helm chart directory to lint
        """
        full_tag = tag or "build-{{ .github.sha }}"

        # Step 1: Build
        built = self.build_image(src_dir, dockerfile)

        # Step 2: SBOM
        _sbom_file = self.sbom(built)

        # Step 3: Scan
        scanned = self.scan_image(built, severity="HIGH,CRITICAL")

        # Step 4: Helm lint (if chart provided)
        if helm_chart_dir:
            linted = self.helm_lint(helm_chart_dir)

        # Step 5: Push (if credentials and tag provided)
        if tag and registry_username and registry_password:
            return self.push_image(
                built,
                Secret("harbor.ebruno.fr"),
                registry_username,
                registry_password,
                full_tag
            )

        return _sbom_file
