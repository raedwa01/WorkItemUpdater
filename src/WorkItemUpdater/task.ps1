#
# WorkItemUpdater.ps1
#
[CmdletBinding(DefaultParameterSetName = 'None')]
param()

$directory = [System.IO.Path]::GetFullPath("$PSScriptRoot\")
$newtonsoftDll = [System.IO.Path]::Combine($directory, "Newtonsoft.Json.dll")
$httpFormatingDll = [System.IO.Path]::Combine($directory, "System.Net.Http.Formatting.dll")
$onAssemblyResolve = [System.ResolveEventHandler]{
    param($sender, $e)

	if ($e.Name -like 'Newtonsoft.Json, *') {
		Write-Host "Resolving '$($newtonsoftDll)'"
		$result = [System.Reflection.Assembly]::LoadFrom($newtonsoftDll)
		Write-Host "Resolved '$($e.Name)'"
		return $result;
	}
	else
	{
		if ($e.Name -like 'System.Net.Http.Formatting, *') {
			Write-Host "Resolving '$($httpFormatingDll)'"
			$result = [System.Reflection.Assembly]::LoadFrom($httpFormatingDll)
			Write-Host "Resolved '$($e.Name)'"
			return $result;
		}
	}
    return $null;
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($onAssemblyResolve)

Import-Module .\ps_modules\VstsTaskSdk\VstsTaskSdk.psm1 -Verbose:$true

Trace-VstsEnteringInvocation $MyInvocation

#
# Invoke a method with optional params by reflection. 
# This can be used to overcome PS bugs in determining the correct overload candidate method from a .net assembly
#
# Remark: this does not work with polymorphic parameters
function InvokeByReflection
{
    param ($obj, $methodName, [Type[]] $parameterTypes, [Object[]] $parameterValues)

    # GetMethod(name, Type[]) could also be used, but the methods tend to have many parameters and to list them all make the code harder to read
    $publicMethods = $obj.GetType().GetMethods() | Where-Object {($_.Name -eq $methodName) -and  ($_.IsPublic -eq $true)}
    if ($publicMethods.Count -eq 0)
    {
        throw "$methodName not found"
    }

    foreach ($method in $publicMethods)
    {
        $methodParams = $method.GetParameters();
        if ((ParamTypesMatch $methodParams $parameterTypes) -eq $true) 
        {
            $paramValuesAndDefaults = New-Object "System.Collections.Generic.List[Object]"
            $paramValuesAndDefaults.AddRange($parameterValues);

            for ($i=0; $i -lt ($methodParams.Length - $parameterValues.Length); $i++)
            {
                $paramValuesAndDefaults.Add([Type]::Missing);
            } 

            return $method.Invoke($obj, [Reflection.BindingFlags]::OptionalParamBinding, $null, $paramValuesAndDefaults.ToArray(), [Globalization.CultureInfo]::CurrentCulture)
        }
    }

    throw "No suitable overload found for $methodName"
}

#
# Returns true if the candidate types match are a subset of method parameter types, on a position by position basis
# 
function ParamTypesMatch
{
   param ([Reflection.ParameterInfo[]] $methodParams, [Type[]] $candidateTypes)

   for ($i=0; $i -lt $candidateTypes.Length; $i++) {
       if ($methodParams[$i].ParameterType -ne $candidateTypes[$i])
       {
           return $false;
       }
   }
  
   return (($methodParams | Select-Object -Skip $candidateTypes.Length | Where-Object {$_.IsOptional -eq $false}).Count -eq 0)
}

function Update-WorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.TeamFoundation.WorkItemTracking.WebApi.WorkItemTrackingHttpClient]$workItemTrackingHttpClient,
        [Parameter(Mandatory = $true)]
        [int]$workItemId,
        [Parameter(Mandatory = $true)]
        [int]$buildId,
        [Parameter(Mandatory = $true)]
        [string]$workItemType,
        [Parameter(Mandatory = $false)]
        [string]$workItemCurrentState,
        [Parameter(Mandatory = $false)]
        [string]$workItemState,
        [Parameter(Mandatory = $false)]
        [string]$workItemKanbanLane,
        [Parameter(Mandatory = $false)]
        [string]$workItemKanbanState,
        [Parameter(Mandatory = $true)]
        [string]$workItemDone,
        [Parameter(Mandatory = $true)]
        [bool]$linkBuild,
        [Parameter(Mandatory = $true)]
        [string]$assignedTo,
        [Parameter(Mandatory = $true)]
        [string]$updateAssignedTo)

    Write-VstsTaskDebug -Message "Found WorkItemRef: $($workItemId)"
    $task = InvokeByReflection $workItemTrackingHttpClient "GetWorkItemAsync" @([int]) ($workItemId, $null, $null, [Microsoft.TeamFoundation.WorkItemTracking.WebApi.Models.WorkItemExpand]::Relations)
    $workItem = $task.Result
    Write-VstsTaskDebug -Message "Found WorkItem: $($workItem.Id)"
    if ($workItem.Fields["System.WorkItemType"] -eq $workItemType)
    {
        if ($workItemCurrentState -ne "" -and $workItemCurrentState -split ',' -notcontains $workItem.Fields["System.State"])
        {
            Write-VstsTaskDebug -Message "Skipped currently $($workItem.Fields["System.State"]) WorkItem: $($workItem.Id)"
            return
        }

        Write-Host "Updating WorkItem $($workItem.Id)"

        $kanbanLane = $workItem.Fields.Keys | Where-Object { $_.EndsWith("Kanban.Lane") }
        Write-VstsTaskDebug -Message "Found Kanban Lane: $($kanbanLane)"
        $kanbanColumn = $workItem.Fields.Keys | Where-Object { $_.EndsWith("Kanban.Column") }
        Write-VstsTaskDebug -Message "Found KanbanColumn: $($kanbanColumn)"
        $kanbanDoneColumn = $workItem.Fields.Keys | Where-Object { $_.EndsWith("Kanban.Column.Done") }
        Write-VstsTaskDebug -Message "Found KanbanDoneColumn: $($kanbanDoneColumn)"

        $patch = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchDocument

        if ($workItemState -ne "")
        {
            $columnOperation = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchOperation
            $columnOperation.Operation = [Microsoft.VisualStudio.Services.WebApi.Patch.Operation]::Add
            $columnOperation.Path = "/fields/System.State"
            $columnOperation.Value = $workItemState
            $patch.Add($columnOperation)
            Write-VstsTaskDebug -Message "Patch: $($columnOperation.Path) $($columnOperation.Value)"
        }

        if ($workItemKanbanLane -ne "" -and $kanbanLane -ne "" -and $kanbanLane -ne $null)
        {
            $kanbanLane.Split(" ") | ForEach-Object {
                $columnBoardLane = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchOperation
                $columnBoardLane.Operation = [Microsoft.VisualStudio.Services.WebApi.Patch.Operation]::Add
                $columnBoardLane.Path = "/fields/$($_)"
                $columnBoardLane.Value = $workItemKanbanLane
                $patch.Add($columnBoardLane)
                Write-VstsTaskDebug -Message "Patch: $($columnBoardLane.Path) $($columnBoardLane.Value)"
            }
        }

        if ($workItemKanbanState -ne "" -and $kanbanColumn -ne "" -and $kanbanColumn -ne $null)
        {
            $kanbanColumn.Split(" ") | ForEach-Object { 
                $columnDoneOperation = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchOperation
                $columnDoneOperation.Operation = [Microsoft.VisualStudio.Services.WebApi.Patch.Operation]::Add
                $columnDoneOperation.Path = "/fields/$($_)"
                $columnDoneOperation.Value = $workItemKanbanState
                $patch.Add($columnDoneOperation)
                Write-VstsTaskDebug -Message "Patch: $($columnDoneOperation.Path) $($columnDoneOperation.Value)"
            }
        }

        if ($kanbanDoneColumn -ne "" -and $kanbanDoneColumn -ne $null) {
            $kanbanDoneColumn.Split(" ") | ForEach-Object { 
                $columnDoneOperation = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchOperation
                $columnDoneOperation.Operation = [Microsoft.VisualStudio.Services.WebApi.Patch.Operation]::Add
                $columnDoneOperation.Path = "/fields/$($_)"
                $columnDoneOperation.Value = $workItemDone
                $patch.Add($columnDoneOperation)
                Write-VstsTaskDebug -Message "Patch: $($columnDoneOperation.Path) $($columnDoneOperation.Value)"
            }
        }

        if ($linkBuild -eq $true)
        {
            $buildRelationUrl = "vstfs:///Build/Build/$buildId"
            $buildRelation = $workItem.Relations | Where-Object { $_.Url -eq $buildRelationUrl }
            if ($buildRelation -eq $null) {
                Write-Host "Linking Build $($buildId) to WorkItem $($workItem.Id)"
                $linkBuildOperation = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchOperation
                $linkBuildOperation.Operation = [Microsoft.VisualStudio.Services.WebApi.Patch.Operation]::Add
                $linkBuildOperation.Path = "/relations/-"
                $linkBuildOperation.Value = @{
                        Rel = "ArtifactLink"
                        Url = $buildRelationUrl
                        Attributes = @{
                            name = "Build"
                        }
                    }
                $patch.Add($linkBuildOperation)
                Write-VstsTaskDebug -Message "Patch: $($linkBuildOperation.Path) $($buildRelationUrl)"
            }
            else {
                Write-Host "Build $($buildId) already linked to WorkItem $($workItem.Id)"
            }
        }
        if ($updateAssignedTo -eq "Always" -or ($updateAssignedTo -eq "Unassigned" -and $workItem.Fields.ContainsKey("System.AssignedTo") -eq $false))
        {
            $assignedToOperation = New-Object Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchOperation
            $assignedToOperation.Operation = [Microsoft.VisualStudio.Services.WebApi.Patch.Operation]::Add
            $assignedToOperation.Path = "/fields/System.AssignedTo"
            $assignedToOperation.Value = $assignedTo
            $patch.Add($assignedToOperation)
            Write-VstsTaskDebug -Message "Patch: $($assignedToOperation.Path) $($assignedToOperation.Value)"
        }

        Write-VstsTaskDebug -Message "Start InvokeByReflection for UpdateWorkItemAsync"
        $task = InvokeByReflection $workItemTrackingHttpClient "UpdateWorkItemAsync" @([Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchDocument], [int]) @([Microsoft.VisualStudio.Services.WebApi.Patch.Json.JsonPatchDocument]$patch, $workItem.Id)
        Write-Host "WorkItem $($workItemId) updated to $($workItemState) $($workItemKanbanState) $($workItemDone)"

        Write-Host $task
    }
    else
    {
        Write-VstsTaskDebug -Message "Skipped $($workItem.Fields['System.WorkItemType']) WorkItem: $($workItem.Id)"
    }
}

try {
    Write-Host "Add-Type Services.WebApi"
    Add-Type -LiteralPath "Microsoft.VisualStudio.Services.WebApi.dll"
    Write-Host "Add-Type WorkItemTracking.WebApi"
    Add-Type -LiteralPath "Microsoft.TeamFoundation.WorkItemTracking.WebApi.dll"
    Write-Host "Added Types"

    $buildId = Get-VstsTaskVariable -Name "Build.BuildId"
    $projectId = Get-VstsTaskVariable -Name "System.TeamProjectId"
    $requestedFor = Get-VstsTaskVariable -Name "Build.RequestedFor"
    $workItemType = Get-VstsInput -Name "workItemType"
    $workItemState = Get-VstsInput -Name "workItemState"
    $workItemCurrentState = Get-VstsInput -Name "workItemCurrentState"
    $workItemKanbanLane = Get-VstsInput -Name "workItemKanbanLane"
    $workItemKanbanState = Get-VstsInput -Name "workItemKanbanState"
    $workItemDone = Get-VstsInput -Name "workItemDone" -AsBool 
    $linkBuild = Get-VstsInput -Name "linkBuild" -AsBool
    $updateAssignedTo = Get-VstsInput -Name "updateAssignedTo"
    $updateAssignedToWith = Get-VstsInput -Name "updateAssignedToWith"
    $assignedTo = Get-VstsInput -Name "assignedTo"

    Write-VstsTaskDebug -Message "BuildId $buildId"
    Write-VstsTaskDebug -Message "ProjectId $projectId"
    Write-VstsTaskDebug -Message "requestedFor $requestedFor"
    Write-VstsTaskDebug -Message "workItemType $workItemType"
    Write-VstsTaskDebug -Message "WorkItemState $workItemState"
    Write-VstsTaskDebug -Message "workItemCurrentState $workItemCurrentState"
    Write-VstsTaskDebug -Message "updateWorkItemKanbanLane $workItemKanbanLane"
    Write-VstsTaskDebug -Message "WorkItemKanbanState $workItemKanbanState"
    Write-VstsTaskDebug -Message "WorkItemDone $workItemDone"
    Write-VstsTaskDebug -Message "updateAssignedTo $updateAssignedTo"
    Write-VstsTaskDebug -Message "updateAssignedToWith $updateAssignedToWith"
    Write-VstsTaskDebug -Message "assignedTo $assignedTo"

    Write-VstsTaskDebug -Message "Converting buildId '$buildId' as int"
    $buildIdNum = $buildId -as [int];

    Write-VstsTaskDebug -Message "Converting projectId '$projectId' as GUID"
    $projectIdGuid = [GUID]$projectId

    if ($updateAssignedToWith -eq "FixedUser") {
        Write-VstsTaskDebug -Message "Using fixed user '$assignedTo' as assignedTo."
    } else {
        Write-VstsTaskDebug -Message "Setting assignedTo to requester for build '$requestedFor'."
        $assignedTo = $requestedFor
    }

    $workItemTrackingHttpClient = Get-VssHttpClient -TypeName Microsoft.TeamFoundation.WorkItemTracking.WebApi.WorkItemTrackingHttpClient
    $buildHttpClient = Get-VssHttpClient -TypeName Microsoft.TeamFoundation.Build.WebApi.BuildHttpClient
    Write-VstsTaskDebug -Message "GetBuildWorkItemsRefsAsync $projectId $buildId"
    $task = InvokeByReflection $buildHttpClient "GetBuildWorkItemsRefsAsync" @([Guid], [int]) @($projectIdGuid, $buildIdNum)
    $workItemsRefs = $task.Result
    Write-VstsTaskDebug -Message "Loop workItemsRefs"
    foreach ($workItemRef in $workItemsRefs)
    {
        Update-WorkItem -workItemTrackingHttpClient $workItemTrackingHttpClient `
            -workItemId $workItemRef.Id `
            -buildId $buildId `
            -workItemType $workItemType `
            -workItemState $workItemState `
            -workItemCurrentState $workItemCurrentState `
            -workItemKanbanLane $workItemKanbanLane `
            -workItemKanbanState $workItemKanbanState `
            -workItemDone $workItemDone `
            -linkBuild $linkBuild `
            -assignedTo $assignedTo `
            -updateAssignedTo $updateAssignedTo
    }
    Write-VstsTaskDebug -Message "Finished loop workItemsRefs"
}
catch {
    Write-Host $_.Exception.Message
    Write-Host $_.Exception.StackTrace
    Write-VstsSetResult -Result "Failed" -Message "Error updating workitems"
}
finally {
    Trace-VstsLeavingInvocation $MyInvocation
}
