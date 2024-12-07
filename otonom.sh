#!/bin/bash

# On-demand instance türleri
instance_types_old=("r7a.16xlarge" "m7a.16xlarge" "c7a.16xlarge")
instance_types_new=("r7i.16xlarge" "m7i.16xlarge" "c7i.16xlarge")

# Eski bölgeler
regions_old=("us-east-1" "us-east-2" "ap-northeast-1" "eu-central-1" "eu-west-1" "eu-north-1")

# Yeni bölgeler
regions_new=("us-west-1" "us-west-2" "eu-west-2" "eu-west-3")

# Her bölge için AMI ID'lerini manuel olarak belirleyin
declare -A ami_ids
ami_ids["us-east-1"]="ami-0866a3c8686eaeeba"
ami_ids["us-east-2"]="ami-0ea3c35c5c3284d82"
ami_ids["ap-northeast-1"]="ami-0b2cd2a95639e0e5b"
ami_ids["eu-central-1"]="ami-0084a47cc718c111a"
ami_ids["eu-west-1"]="ami-0d64bb532e0502c46"
ami_ids["eu-north-1"]="ami-075449515af5df0d1"
ami_ids["us-west-1"]="ami-0da424eb883458071"
ami_ids["us-west-2"]="ami-04dd23e62ed049936"
ami_ids["eu-west-2"]="ami-0e8d228ad90af673b"
ami_ids["eu-west-3"]="ami-045a8ab02aadf4f88"

# Başarılı ve başarısız bölgeler için diziler
success_regions=()
failed_regions=()

# Tanımlı türler dışındaki instance'ları silme fonksiyonu
terminate_other_instances() {
    local region=$1
    local allowed_types=("${!2}")  # Tanımlanan türler

    # Mevcut instance'ları kontrol et
    instances=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[?(!contains('${allowed_types[*]}', InstanceType))].InstanceId" \
        --output text)

    if [ -n "$instances" ]; then
        echo "$region bölgesinde tanımlanan türlerin dışında çalışan instance'lar bulundu: $instances"
        aws ec2 terminate-instances --region "$region" --instance-ids $instances
        echo "$region bölgesindeki tanımlanmayan türdeki instance'lar silindi."
    else
        echo "$region bölgesinde yalnızca tanımlanan türlerde instance'lar var."
    fi
}

# Uygun instance türü bulma fonksiyonu
find_instance_type() {
    local region=$1
    local types=("$@")  # Alınan sunucu türlerini listele
    for instance_type in "${types[@]:1}"; do
        available=$(aws ec2 describe-instance-type-offerings \
            --region "$region" \
            --filters "Name=instance-type,Values=$instance_type" "Name=location,Values=$region" \
            --query "InstanceTypeOfferings | length(@)" --output text)
        if [ "$available" -gt 0 ]; then
            echo "$instance_type"
            return
        fi
    done
    echo ""
}

# On-demand instance talebi oluşturma fonksiyonu
create_on_demand_request() {
    local region=$1
    local types=("$@")  # Alınan sunucu türlerini listele
    echo "Bölge: $region"
    
    # Bölgeye göre doğru instance türünü bul
    if [[ " ${regions_old[@]} " =~ " $region " ]]; then
        instance_type=$(find_instance_type "$region" "${instance_types_old[@]}")
    else
        instance_type=$(find_instance_type "$region" "${instance_types_new[@]}")
    fi
    
    if [ -z "$instance_type" ]; then
        echo "$region bölgesinde uygun bir instance türü bulunamadı."
        return
    fi
    echo "Seçilen instance türü: $instance_type"
    
    # Manuel AMI ID'sini kullan
    ami_id=${ami_ids[$region]}
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        return
    fi

    # Default güvenlik grubunu kullan
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=default" \
        --query "SecurityGroups[0].GroupId" \
        --output text)

    # Default güvenlik grubuna SSH port 22 izni ekle
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true

    # Alt ağ (Subnet) ID'sini bul
    subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)
    
    if [ "$subnet_id" == "None" ]; then
        echo "$region bölgesinde alt ağ bulunamadı."
        return
    fi

    # On-demand instance talebi oluştur
    echo "$region bölgesinde uygun bir tür için on-demand instance talebi oluşturuluyor..."
    
    instance_id=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --security-group-ids "$security_group_id" \
        --subnet-id "$subnet_id" \
        --count 1 \
        --query 'Instances[0].InstanceId' --output text)
    
    echo "On-demand instance talebi oluşturuldu: $instance_id"
    success_regions+=("$region:$instance_type")
}

# Eski bölgeler için talepler
for region in "${regions_old[@]}"; do
    terminate_other_instances "$region" instance_types_old[@]
    create_on_demand_request "$region" "${instance_types_old[@]}"
done

# Yeni bölgeler için talepler
for region in "${regions_new[@]}"; do
    terminate_other_instances "$region" instance_types_new[@]
    create_on_demand_request "$region" "${instance_types_new[@]}"
done

# Sonuçları yazdırma
echo "İşlem sonuçları:"
for result in "${success_regions[@]}"; do
    echo "$result"
done