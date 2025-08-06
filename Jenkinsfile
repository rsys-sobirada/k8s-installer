pipeline {
    agent any
    parameters {
        string(name: 'MAX_PARALLEL', defaultValue: '5', description: 'Maximum number of servers to install in parallel')
    }
    stages {
        stage('Install Kubernetes') {
            steps {
                script {
                    def serverLines = readFile('server_pci_map.txt').split("\n")
                    def serverMap = [:]
                    for (line in serverLines) {
                        def parts = line.trim().split(",")
                        if (parts.size() == 2) {
                            serverMap[parts[0].trim()] = parts[1].trim()
                        }
                    }

                    def serverList = serverMap.keySet().toList()
                    def batches = serverList.collate(params.MAX_PARALLEL.toInteger())

                    for (batch in batches) {
                        def parallelStages = [:]
                        for (server in batch) {
                            def pci = serverMap[server]
                            parallelStages["Install on ${server}"] = {
                                sh "./install_cluster.sh '${server}' '${pci}'"
                            }
                        }
                        parallel parallelStages
                    }
                }
            }
        }
    }
}
