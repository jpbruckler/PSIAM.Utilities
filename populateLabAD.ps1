$createOUs = Get-Content .\lab_ous.json -Raw | ConvertFrom-Json

# Create parent OUs that don't exist
$createOUs | Where-Object Parent -eq $null | Foreach-Object {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($_.Name)'")) {
        New-ADOrganizationalUnit -Name $_.Name -DisplayName $_.Name -Description 'Test lab generated OU' -Verbose
    }
}

# Create child OUs
$createOUs | Where-Object Parent -ne $null | Foreach-Object {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($_.Name)'")) {
        New-ADOrganizationalUnit -Name $_.Name -DisplayName $_.Name -Description 'Test lab generated OU' -Path "OU=$($_.Parent),DC=lab,DC=local" -Verbose
    }
}

# Create users
$users = Get-Content .\lab_userlist.json -Raw | ConvertFrom-Json
foreach ($user in $users) {
    if (Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'") {
        Write-Warning "User $($user.SamAccountName) already exists. Skipping."
        continue
    }
    else {

        # generate a random password
        $password = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 12 | Foreach-Object {[char]$_}) | ConvertTo-SecureString -AsPlainText -Force

        # Create the user
        $splat = @{
            Enabled = $true
            Name = $user.SamAccountName
            GivenName = $user.GivenName
            Surname = $user.Surname
            SamAccountName = $user.SamAccountName
            UserPrincipalName = $user.UserPrincipalName
            DisplayName = $user.DisplayName
            EmailAddress = $user.EmailAddress
            Department = $user.Department
            Title = $user.Title
            Office = $user.Office
            AccountPassword = $password
            OfficePhone = $user.TelephoneNumber
            Mobile = $user.Mobile
            EmployeeID = $user.EmployeeID
            Path = $user.DistinguishedName.split(',', 2)[1]
        }
        New-ADUser @splat -Verbose
        if ($user.thumbnailPhoto) {
            $Photo = [byte[]]$user.thumbnailPhoto
            Set-ADUser -Identity $user.SamAccountName -Replace @{thumbnailPhoto = $Photo} -Verbose
        }
    }
}

# Set managers
$users | Foreach-Object { Set-ADUser -Identity $_.SamAccountName -Manager $_.Manager -Verbose }

# create groups
$groups = Get-Content .\lab_groups.json -Raw | ConvertFrom-Json

foreach ($group in $groups) {
    if (Get-ADGroup -Filter "Name -eq '$($group.Name)'") {
        Write-Warning "Group $($group.Name) already exists. Skipping."
        continue
    }

    New-ADGroup -Name $group.Name -GroupScope DomainLocal -GroupCategory Security -Description $group.Description -Verbose

    # Add members
    foreach ($member in $group.Members) {
        Add-ADGroupMember -Identity $group.Name -Members $member -Verbose
    }
}
