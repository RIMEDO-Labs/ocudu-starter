

helm install open5gs-operator oci://registry-1.docker.io/gradiantcharts/open5gs-operator

kubectl apply -f open5gs-pv-pvc.yaml

kubectl apply -f open5gs-deployment.yaml