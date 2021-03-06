# NuoDB Storage Class Helm Chart

This chart installs NuoDB storage classes in a Kubernetes cluster using the Helm package manager. The use of this chart is optional. Existing storage options are:

- Install this chart and select one of the storage classes in the charts
- Install any other storage class and select them in the charts
- Install any other storage classes and mark one as the default. No changes to the charts are required then.

## Command

```bash
helm install [name] nuodb/storage-class [--generate-name] [--set parameter] [--values myvalues.yaml]
```

## Software Version Prerequisites

Please visit the **[NuoDB Helm Chart main page](https://github.com/nuodb/nuodb-helm-charts/#software-release-requirements)** for software version prerequisites.

## Installing the Chart

All configurable parameters for each top-level scope are detailed below, organized by scope.

#### cloud.*

The purpose of this section is to specify the cloud provider, and specify the availability zones where a solution is deployed.

The following tables list the configurable parameters for the `cloud` option:

| Parameter | Description | Default |
| ----- | ----------- | ------ |
| `provider` | Cloud provider; permissible values include: `azure`, `amazon`, or `google` |`nil`|
| `zones` | List of availability zones to deploy to |`[]`|

For example, for the Google Cloud:

```yaml
cloud:
  provider: google
  zones:
    - us-central1-a
    - us-central1-b
    - us-central1-c
```

#### storageClass.*

The purpose of this section is to specify the storage class parameters. These parameters are applied to all storage classes created by this chart.

The following tables list the configurable parameters for the `storageClass` option:

| Parameter | Description | Default |
| ----- | ----------- | ------ |
| `allowVolumeExpansion` | Persistent Volumes can be configured to be expandable. This feature when set to true, allows the users to resize the volume by editing the corresponding PVC object. |`true`|
| `reclaimPolicy` | PersistentVolumes can have various reclaim policies, including "Retain", "Recycle", and "Delete". For dynamically provisioned PersistentVolumes, the default Kubernetes reclaim policy is "Delete". NuoDB changes this default to "Retain". |`Retain`|

### Running

Verify the Helm chart:

```bash
helm install storage-class nuodb/storage-class --debug --dry-run
```

Deploy the storage classes:

```bash
helm install storage-class nuodb/storage-class 
```

## Uninstalling the Chart

To uninstall/delete the deployment:

```bash
helm delete storage-class
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

[0]: #permissions
