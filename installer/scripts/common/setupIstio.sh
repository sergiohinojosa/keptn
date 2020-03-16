#!/bin/bash
source ./common/utils.sh

kubectl get ns istio-system
ISTIO_AVAILABLE=$?
if [[ "$ISTIO_AVAILABLE" == 0 ]] && [[ "$ISTIO_INSTALL_OPTION" == "Reuse" ]]; then
    # An istio-version is already installed
    print_info "Istio installation is reused but its compatibility is not checked"
elif [[ "$ISTIO_AVAILABLE" == 0 ]] && ([[ "$ISTIO_INSTALL_OPTION" == "StopIfInstalled" ]] || [[ "$ISTIO_INSTALL_OPTION" == "" ]] || [[ "$ISTIO_INSTALL_OPTION" == "ISTIO_INSTALL_OPTION_PLACEHOLDER" ]]); then
    print_error "Istio is already installed but is not used due to unknown compatibility"
    exit 1
else
    if [[ "$ISTIO_AVAILABLE" == 0 ]] && [[ "$ISTIO_INSTALL_OPTION" == "Overwrite" ]]; then
        print_info "Istio installation is overwritten"
    fi

    # Istio installation
    echo "Install Istio"
    kubectl create namespace istio-system

    helm template ../manifests/istio/helm/istio-init --name istio-init --namespace istio-system | kubectl apply -f -
    verify_kubectl $? "Creating Istio resources failed"
    wait_for_crds "adapters.config.istio.io,attributemanifests.config.istio.io,authorizationpolicies.rbac.istio.io,clusterrbacconfigs.rbac.istio.io,destinationrules.networking.istio.io,envoyfilters.networking.istio.io,gateways.networking.istio.io,handlers.config.istio.io,httpapispecbindings.config.istio.io,httpapispecs.config.istio.io,instances.config.istio.io,meshpolicies.authentication.istio.io,policies.authentication.istio.io,quotaspecbindings.config.istio.io,quotaspecs.config.istio.io,rbacconfigs.rbac.istio.io,rules.config.istio.io,serviceentries.networking.istio.io,servicerolebindings.rbac.istio.io,serviceroles.rbac.istio.io,sidecars.networking.istio.io,templates.config.istio.io,virtualservices.networking.istio.io"

    # We tested it with helm --set according to the descriptions provided in https://istio.io/docs/setup/install/helm/
    # However, it did not work out. Therefore, we are using sed
    sed 's/LoadBalancer #change to NodePort, ClusterIP or LoadBalancer if need be/'$GATEWAY_TYPE'/g' ../manifests/istio/helm/istio/charts/gateways/values.yaml  > ../manifests/istio/helm/istio/charts/gateways/values_tmp.yaml
    mv ../manifests/istio/helm/istio/charts/gateways/values_tmp.yaml ../manifests/istio/helm/istio/charts/gateways/values.yaml
    helm template ../manifests/istio/helm/istio --name istio --namespace istio-system --values ../manifests/istio/helm/istio/values-istio-minimal.yaml | kubectl apply -f -
    verify_kubectl $? "Installing Istio failed."
    wait_for_deployment_in_namespace "istio-ingressgateway" "istio-system"
    wait_for_deployment_in_namespace "istio-pilot" "istio-system"
    wait_for_deployment_in_namespace "istio-citadel" "istio-system"
    wait_for_deployment_in_namespace "istio-sidecar-injector" "istio-system"
    wait_for_all_pods_in_namespace "istio-system"
fi

# Domain used for routing to keptn services
if [[ "$GATEWAY_TYPE" == "LoadBalancer" ]]; then
  
  print_info "Check if there is a custom domain to override"
  CUSTOM_DOMAIN=$(kubectl get configmap keptn-domain -o=jsonpath='{.data.domain}')
  if [ $CUSTOM_DOMAIN ]; then
      print_info "Custom domain found $CUSTOM_DOMAIN\n Warning, there will be no validation of the domain nor istio-ingressgateway\n"
      export DOMAIN=$CUSTOM_DOMAIN
      export INGRESS_HOST=$DOMAIN
  else
      wait_for_istio_ingressgateway "hostname"
      export DOMAIN=$(kubectl get svc istio-ingressgateway -o json -n istio-system | jq -r .status.loadBalancer.ingress[0].hostname)
      if [[ $? != 0 ]]; then
          print_error "Failed to get ingress gateway information." && exit 1
      fi
      export INGRESS_HOST=$DOMAIN

      if [[ "$DOMAIN" == "null" ]]; then
          print_info "Could not get ingress gateway domain name. Trying to retrieve IP address instead."
          wait_for_istio_ingressgateway "ip"
          export DOMAIN=$(kubectl get svc istio-ingressgateway -o json -n istio-system | jq -r .status.loadBalancer.ingress[0].ip)
          if [[ "$DOMAIN" == "null" ]]; then
              print_error "IP of Istio ingress gateway could not be derived."
              exit 1
          fi
          export DOMAIN="$DOMAIN.xip.io"
          export INGRESS_HOST=$DOMAIN
      fi
  fi 
elif [[ "$GATEWAY_TYPE" == "NodePort" ]]; then
    NODE_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    NODE_IP=$(kubectl get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{ $.items[0].status.addresses[?(@.type=="InternalIP")].address }')
    export DOMAIN="$NODE_IP.xip.io:$NODE_PORT"
    export INGRESS_HOST="$NODE_IP.xip.io"
fi

echo $DOMAIN
echo $INGRESS_HOST

if [[ "$PLATFORM" == "eks" ]]; then 
    print_info "For EKS: No SSL certificate created. Please use keptn configure domain at the end of the installation."
else
    # Set up SSL
    openssl req -nodes -newkey rsa:2048 -keyout key.pem -out certificate.pem  -x509 -days 365 -subj "/CN=$INGRESS_HOST"

    kubectl create --namespace istio-system secret tls istio-ingressgateway-certs --key key.pem --cert certificate.pem
    #verify_kubectl $? "Creating secret for istio-ingressgateway-certs failed."

    rm key.pem
    rm certificate.pem
fi
