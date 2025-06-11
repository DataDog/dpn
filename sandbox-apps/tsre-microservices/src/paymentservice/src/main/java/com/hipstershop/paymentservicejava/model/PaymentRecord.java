package com.hipstershop.paymentservicejava.model;

import javax.persistence.Entity;
import javax.persistence.GeneratedValue;
import javax.persistence.GenerationType;
import javax.persistence.Id;

@Entity(name = "paymentrecord")
public class PaymentRecord {
    
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private long id;
    private String creditcardnumber;
    private Integer expirationMonth;
    private Integer expirationYear;
    private String cvvcode;
    private Double amount;
    private String paymentstatus;
    
    public long getId() {
        return id;
    }
    public void setId(long id) {
        this.id = id;
    }
    public String getCreditcardnumber() {
        return creditcardnumber;
    }
    public void setCreditcardnumber(String creditcardnumber) {
        this.creditcardnumber = creditcardnumber;
    }
    public Integer getExpirationMonth() {
        return expirationMonth;
    }
    public void setExpirationMonth(Integer expirationMonth) {
        this.expirationMonth = expirationMonth;
    }
    public Integer getExpirationYear() {
        return expirationYear;
    }
    public void setExpirationYear(Integer expirationYear) {
        this.expirationYear = expirationYear;
    }
    public String getCvvcode() {
        return cvvcode;
    }
    public void setCvvcode(String cvvcode) {
        this.cvvcode = cvvcode;
    }
    public Double getAmount() {
        return amount;
    }
    public void setAmount(Double amount) {
        this.amount = amount;
    }
    public String getPaymentstatus() {
        return paymentstatus;
    }
    public void setPaymentstatus(String paymentstatus) {
        this.paymentstatus = paymentstatus;
    }

    

}
