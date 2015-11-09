#!/bin/bash
#readarray antproperties < ant.properties
. clustersetup.properties

echo ${antproperties[@]}
 
nodes=(`grep ^node clustersetup.properties | sed -e 's/^node.=//g'`)
users=(`grep ^username clustersetup.properties | sed -e 's/^username.=//g'`)
distfolders=(`grep ^distfolder clustersetup.properties | sed -e 's/^distfolder.=//g'`)

echo Cluster nodes are : ${nodes[@]}
echo Load balancer is  : $balancer

########### Start of Functions ##########
checkoutAndDist(){
  echo
  echo "... Starting SVN Checkout ..."
  echo
  echo "Checking out source from $svnurl with revision $revision to $checkoutfolder ....."
  
  tempfolder=$checkoutfolder/r$revision
  mkdir $tempfolder
  if [ $? = 0 ]; then inf "$tempfolder folder created successfully"; else err "$tempfolder folder creation failed";exit 1; fi
  cd $tempfolder
  rm -rf *
  svn co -r$revision $svnurl
  if [ $? = 0 ]; then inf "SVN checkout is successfull"; else err "SVN checkout failed";exit 1; fi

  svnurl=${svnurl%/}
  trunk=${svnurl##*/} # here trunk or branch
  cd $trunk

  echo
  echo "... Preparing distribution ..."
  echo

  ant clean dist
  cd target/layout
  ant dist
  if [ $? = 0 ]; then inf "dist is successfull"; else err "dist is unsuccessful - exiting now";exit 1; fi
}

getLocalLayout(){
  tempfolder=$checkoutfolder/r$revision
  svnurl=${svnurl%/}
  trunk=${svnurl##*/} # here trunk or branch
  cd $tempfolder/$trunk/target/layout/target/dist
  distfilename=`ls`
  cd ~
  foldername=`basename $distfilename .tar.gz`;
}

copyDist(){
  getLocalLayout
  cd $tempfolder/$trunk/target/layout/target/dist
  if [ $? = 0 ]; then inf "target/dist is available"; else err "copyDist failed; Unable to cd to target/dist in local machine";exit 1; fi
  distfilename=`ls`
  distfiles=($distfilename)
  if [ ${#distfiles[@]} = 1 ]; then inf "dist file is available"; else err "copyDist failed; Invalid dist file/files in local machine";exit 1; fi
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]}
    user=${users[$i]}
    distfolder=${distfolders[$i]}
    
    if [ $i -eq  0 ]
      then
	  echo "Copying $distfilename from local machine...";
          scp $distfilename $user@$node:$distfolder
	  if [ $? = 0 ]; then inf "copyDist is successfull to $node"; else wrn "copyDist failed to $node";fi
          ssh $user@$node "tar -xvf $distfolder/$distfilename -C $distfolder"
          if [ $? = 0 ]; then inf "copyDist untar is successfull to $node"; else wrn "copyDist untar failed to $node"; fi
          
      else
          echo "Copying $distfilename from remote machines...";
   	  scp ${users[$i-1]}@${nodes[$i-1]}:${distfolders[$i-1]}/$distfilename $user@$node:${distfolders[$i]}
	  if [ $? = 0 ]; then inf "copyDist is successfull to $node"; else wrn "copyDist failed to $node";fi
       	  ssh $user@$node "tar -xvf $distfolder/$distfilename -C $distfolder"	  
	  if [ $? = 0 ]; then inf "copyDist untar is successfull to $node"; else wrn "copyDist untar failed to $node";fi
    fi 
  done
}

killNode(){
	echo "Killing $2"
	processId=`ssh $1@$2 pgrep -lf java | grep tomcat| awk '{print $1}'`
	echo "Killing tomcat process on $2 with processId $processId"
	ssh $1@$2 kill -9 $processId	
	if [ $? = 0 ]; then inf "Successfully killed tomcat process on $2 with processId $processId"; else inf "Tomcat instance is already down on $2"; fi
}

killAllNodes(){
  echo  
  echo "... Killing all nodes ...";
  echo
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    killNode $user $node;
  done
}

startNode(){
	echo "Starting $2"
	getLocalLayout
	ssh $1@$2 "source ~/.bash_profile; cd $3/$foldername/tomcat/logs; ../bin/startup.sh;";
	if [ $? = 0 ]; then inf "$2 was started successfully"; else wrn "$2 was failed to start"; fi
}

startAllNodes(){
  echo
  echo "... Starting all nodes ...";
  echo
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    distfolder=${distfolders[$i]};
    
    startNode $user $node $distfolder;
  done
}

restartAllNodes(){
  killAllNodes
  startAllNodes
}
configCluster(){
  echo 
  echo "... Configuring cluster nodes ...";
  echo
  getLocalLayout
  deleteUserPrefs
  if [ $? = 0 ]; then inf "deleteUserPrefs is successfull"; else err "deleteUserPrefs is unsuccessful - exiting now";exit 1; fi
  updateUserPrefs
  if [ $? = 0 ]; then inf "updateUserPrefs is successfull"; else err "updateUserPrefs is unsuccessful - exiting now";exit 1; fi
  copyUserPrefs
  if [ $? = 0 ]; then inf "copyUserPrefs is successfull"; else err "copyUserPrefs is unsuccessful - exiting now";exit 1; fi
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    distfolder=${distfolders[$i]};

    echo "Configuring $node ...";
    ssh ${users[$i]}@${nodes[$i]} "\
	cd $distfolder/$foldername/tomcat;\
	cp etc/conf/server.xml conf;\
	cp etc/conf/context.xml conf;\
		
	sed -i 's/127.0.0.1/$node/g' lib/jgroups.xml;\
	sed -i 's/machine1/$node/g' conf/server.xml;\
	sed -i 's/balancer1/$balancer/g' conf/server.xml;\
  	sed -i 's/ttl:[0-9]*/ttl:$ttl/g' lib/jgroups.xml;\
  	sed -i 's/127.0.0.1/$node/g' bin/catalina.sh;\
	echo "Configuration completed successfully ...""	
  done
  if [ $? = 0 ]; then inf "configCluster is successfull"; else err "configCluster is unsuccessful - exiting now";exit 1 ;fi
}

cleanRemoteBuilds(){
  echo
  echo "... Removing builds on all nodes ...";
  echo
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    distfolder=${distfolders[$i]};
    cleanRemoteBuild $user $node $distfolder;
  done
}

cleanLocalBuild(){
	rm -rf $checkoutfolder/r[0-9][0-9][0-9][0-9][0-9][0-9]
	if [ $? = 0 ]; then inf "rxxxx local checkout folder deleted successfully"; else wrn "rxxxx local checkout folder delete failed";fi
}

cleanRemoteBuild(){
	ssh $1@$2 "cd $3; rm -rf aepona-pse-bin-*"
	if [ $? = 0 ]; then inf "$2 remote checkout folder deleted successfully"; else wrn "$2 remote checkout folder delete failed";fi
}

updateUserPrefs(){
  echo "Updating .java/.userPrefs";
  sed -i 's/"enabled" value=.*/"enabled" value="'$dbenabled'"\/>/g;
          s/"url" value=.*/"url" value="'$dburl'"\/>/g;
          s/"password" value=.*/"password" value="'$dbpassword'"\/>/g;
          s/"username" value=.*/"username" value="'$dbusername'"\/>/g;' clustersetup-data/databaseConnector/prefs.xml

  sed -i 's/"multicastAddress" value=.*/"multicastAddress" value="'$multicastaddress'"\/>/g;
          s/"multicastHops" value=.*/"multicastHops" value="'$multicasthops'"\/>/g;' clustersetup-data/replicationAgent/prefs.xml
}

copyUserPrefs(){
  echo 
  echo "... Copying userPrefs ...";
  echo
  
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    ssh $user@$node "mkdir -p .java/.userPrefs/aepona/paymentsAndSettlement/databaseConnector;mkdir -p .java/.userPrefs/aepona/paymentsAndSettlement/agents/replicationAgent;";    
    scp clustersetup-data/databaseConnector/prefs.xml $user@$node:.java/.userPrefs/aepona/paymentsAndSettlement/databaseConnector/
    scp clustersetup-data/replicationAgent/prefs.xml $user@$node:.java/.userPrefs/aepona/paymentsAndSettlement/agents/replicationAgent/	
  done
}

deleteUserPrefs(){
  echo 
  echo "... Deleting userPrefs ...";
  echo
  
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    ssh $user@$node "mkdir -p .java/*;"; 
  done
}

removeLogs(){
	echo "Removing tomcat logs on $2"
	getLocalLayout

	ssh $1@$2 "source ~/.bash_profile; cd $3/$foldername/tomcat/logs; rm -rf *.log *.log.* *.out;";
	if [ $? = 0 ]; then inf "removeLogs is successfull"; else wrn "removeLogs is unsuccessful - exiting now"; fi
}

removeLogsOnAllNodes(){
  echo
  echo "... Removing tomcat logs on all nodes ...";
  echo
  for ((i=0 ; i<${#nodes[@]}; ++i));
  do
    node=${nodes[$i]};
    user=${users[$i]};
    distfolder=${distfolders[$i]};
    removeLogs $user $node $distfolder;
  done
}


executeQuery(){
	getLocalLayout
	ssh oracle@$dbserver "source ~/.bash_profile; sqlplus -s /nolog <<-EOF;
	connect $1/$2@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(Host=$dbserver)(Port=1521))(CONNECT_DATA=(SID=$dbsid))) as sysdba;
	@@db$revision/$3
	exit;
	EOF;"	
	if [ $? = 0 ]; then inf "executeQuery of $3 is successfull"; else wrn "executeQuery of $3 is unsuccessful - exiting now"; fi  
}

dropUser(){
	echo "dropUser"
	executeQuery $dbsystemuser $dbsystempassword drop-user.sql;
}

dropSuperUser(){
	echo "dropSuperUser"
	executeQuery $dbsystemuser $dbsystempassword drop-pse-super-user.sql;
}

dropTablespaces(){
	echo "dropTablespaces"
	executeQuery $dbsystemuser $dbsystempassword drop-tablespaces.sql;
}

createTablespaces(){
	echo "createTablespaces"
	executeQuery $dbsystemuser $dbsystempassword create-tablespaces.sql ;
}

createUser(){
	echo "createUser"
	executeQuery $dbsystemuser $dbsystempassword create-user.sql;
	if [ $? = 0 ]; then inf "createUser is successfull"; else err "createUser is unsuccessful - exiting now";exit 1; fi  
}
createSuperUser(){
	echo "createSuperUser"
	executeQuery $dbsystemuser $dbsystempassword create-pse-super-user.sql;
	if [ $? = 0 ]; then inf "createSuperUser is successfull"; else err "createSuperUser is unsuccessful - exiting now";exit 1; fi
}
lockSuperUser(){
	echo "lockSuperUser"
	executeQuery $dbsystemuser $dbsystempassword lock-pse-super-user.sql;
	if [ $? = 0 ]; then inf "lockSuperUser is successfull"; else wrn "lockSuperUser is unsuccessful - exiting now"; fi
}

updatePropertiesSE(){
	getLocalLayout
	if ssh ${users[0]}@${nodes[0]} [ ! -f ${distfolders[0]}/$foldername/core/db/liquibase.properties_bkp ];
	then 
		ssh ${users[0]}@${nodes[0]} "cp ${distfolders[0]}/$foldername/core/db/liquibase.properties ${distfolders[0]}/$foldername/core/db/liquibase.properties_bkp;"
	else
		echo "liquibase.properties_bkp is already exists"
		ssh ${users[0]}@${nodes[0]} "cp ${distfolders[0]}/$foldername/core/db/liquibase.properties_bkp ${distfolders[0]}/$foldername/core/db/liquibase.properties;"
	fi
 
  	ssh ${users[0]}@${nodes[0]} "cd  ${distfolders[0]}/$foldername/core/db/;
	sed -i 's/username=.*/username=$dbusername/g;
		s/password=.*/password=$dbpassword/g;
		s/url=.*/url=$dburl/g;
		s/liquibase.schemaName=/liquibase.schemaName=$dbusername/g;
		s/db.tablespace.index=.*/db.tablespace.index=QA_IDX_$dbusername/g;
		s/db.tablespace.partitioned.index=.*/db.tablespace.partitioned.index=QA_IDX_$dbusername/g;
		s/USERS/QA_DATA_$dbusername/g;
		s/db.tablespace.db.job.log.dir.path=/db.tablespace.db.job.log.dir.path=./g;' liquibase.properties"
	if [ $? = 0 ]; then inf "updatePropertiesSE is successfull"; else err "updatePropertiesSE is unsuccessful - exiting now";exit 1; fi
}

updatePropertiesEE(){
	getLocalLayout 
  	ssh ${users[0]}@${nodes[0]} "cd  ${distfolders[0]}/$foldername/core/db/;
	sed -i 's/changeLogFile=.*/changeLogFile=oracle-ee-mig.changelog/g;
		s/username=.*/'username=$dbusername'_super/g;
		s/password=.*/password=$dbsuperpassword/g;' liquibase.properties"
	if [ $? = 0 ]; then inf "updatePropertiesEE is successfull"; else err "updatePropertiesEE is unsuccessful - exiting now";exit 1; fi
}

migrateDatabase(){
	ssh ${users[0]}@${nodes[0]} "source ~/.bash_profile; cd ${distfolders[0]}/$foldername/core/db;liquibase/liquibase migrate;"
	if [ $? = 0 ]; then inf "migrateDatabase is successfull"; else err "migrateDatabase is unsuccessful - exiting now";exit 1; fi
}

recreateDatabase(){
  copyQueries
  updateQueries
  dropUser
  dropSuperUser;
  dropTablespaces;
  createTablespaces;
  createUser;
  updatePropertiesSE;
  migrateDatabase;
  updatePropertiesEE;
  createSuperUser
  migrateDatabase;
  lockSuperUser;
}

copyQueries(){
  getLocalLayout
  ssh oracle@$dbserver "rm -rf db$revision;mkdir db$revision;"
  scp $tempfolder/$trunk/qa/etc/*.sql oracle@$dbserver:db$revision;
  if [ $? = 0 ]; then inf "copyQueries is successfull to $dbserver"; else err "copyQueries is unsuccessful to $dbserver - exiting now";exit 1; fi  
}

updateQueries(){
	echo "updateQueries"
	ssh oracle@$dbserver "\
	sed -i 's/@db.users.owner.username@/$dbusername/g;\
		s/@db.users.owner.password@/$dbpassword/g;\
		s/@db.tabalespace.location@/$dbtablespacelocation/g;' db$revision/*.sql"
	if [ $? = 0 ]; then inf "updateQueries is successfull to $dbserver"; else err "updateQueries is unsuccessful to $dbserver - exiting now";exit 1; fi  
}

wrn()
{
	if [ ! -f ~/clustersetup.log ];
		then touch ~/clustersetup.log;
	fi
	echo -e "`date +"%Y-%m-%d %T"` [WARN] : $1" >> ~/clustersetup.log
}

err()
{
	if [ ! -f ~/clustersetup.log ];
		then touch clustersetup.log;
	fi
	echo -e "`date +"%Y-%m-%d %T"` [ERROR] : $1" >> ~/clustersetup.log
}

inf()
{
	if [ ! -f ~/clustersetup.log ];
		then touch ~/clustersetup.log;
	fi
	echo -e "`date +"%Y-%m-%d %T"` [INFO] : $1" >> ~/clustersetup.log
}



ext()
{
	echo "$1" 1>&2
	exit 1
}

##################################End of Functions########################################
killAllNodes

#cleanLocalBuild

#cleanRemoteBuilds

#checkoutAndDist

#copyDist

#recreateDatabase

removeLogsOnAllNodes

configCluster

startAllNodes

#########################################################################################
#killNode pseuser oran.aepona.com
#startNode thushan eng65.aepona.com
#cleanRemoteBuild pseuser oran.aepona.com
